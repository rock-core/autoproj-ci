# frozen_string_literal: true

require 'autoproj/cli/inspection_tool'
require 'tmpdir'

module Autoproj
    module CLI
        # Actual implementation of the functionality for the `autoproj ci` subcommand
        #
        # Autoproj internally splits the CLI definition (Thor subclass) and the
        # underlying functionality of each CLI subcommand. `autoproj-ci` follows the
        # same pattern, and registers its subcommand in {MainCI} while implementing
        # the functionality in this class
        class CI < InspectionTool
            PHASES = %w[import build test].freeze

            def resolve_packages
                initialize_and_load
                source_packages, * = finalize_setup(
                    [], non_imported_packages: :ignore
                )
                source_packages.map do |pkg_name|
                    ws.manifest.find_autobuild_package(pkg_name)
                end
            end

            def cache_state(dir, ignore: [])
                packages = resolve_packages

                memo = {}
                packages.each_with_object({}) do |pkg, h|
                    state = package_cache_state(dir, pkg, memo: memo)
                    if ignore.include?(pkg.name)
                        state = state.merge('cached' => false, 'metadata' => false)
                    end

                    h[pkg.name] = state
                end
            end

            def cache_pull(dir, ignore: [], silent: true)
                packages = resolve_packages

                memo = {}
                results = packages.each_with_object({}) do |pkg, h|
                    if ignore.include?(pkg.name)
                        fingerprint = pkg.fingerprint(memo: memo)
                        h[pkg.name] = {
                            'cached' => false,
                            'fingerprint' => fingerprint
                        }
                        next
                    end

                    state, fingerprint, metadata =
                        pull_package_from_cache(dir, pkg, memo: memo)
                    puts "pulled #{pkg.name} (#{fingerprint})" if state && !silent

                    h[pkg.name] = metadata.merge(
                        'cached' => state,
                        'fingerprint' => fingerprint
                    )
                end

                unless silent
                    hit = results.count { |_, info| info['cached'] }
                    puts "#{hit} hits, #{results.size - hit} misses"
                end

                results
            end

            def cache_push(dir, silent: true)
                packages = resolve_packages
                metadata = consolidated_report['packages']

                memo = {}
                results = packages.each_with_object({}) do |pkg, h|
                    next unless (pkg_metadata = metadata[pkg.name])
                    next unless (build_info = pkg_metadata['build'])
                    next if build_info['cached'] || !build_info['success']

                    # Remove cached flags before saving
                    pkg_metadata = pkg_metadata.dup
                    PHASES.each do |phase_name|
                        pkg_metadata[phase_name]&.delete('cached')
                    end

                    state, fingerprint = push_package_to_cache(
                        dir, pkg, pkg_metadata, force: true, memo: memo
                    )
                    puts "pushed #{pkg.name} (#{fingerprint})" if state && !silent

                    h[pkg.name] = {
                        'updated' => state,
                        'fingerprint' => fingerprint
                    }
                end

                unless silent
                    hit = results.count { |_, info| info['updated'] }
                    puts "#{hit} updated packages, #{results.size - hit} reused entries"
                end

                results
            end

            # Checks if a package's test results should be processed with xunit-viewer
            #
            # @param [String] results_dir the directory where the
            # @param [String] xunit_output path to the xunit-viewer output. An
            #   existing file is re-generated only if force is true
            # @param [Boolean] force re-generation of the xunit-viewer output
            def need_xunit_processing?(results_dir, xunit_output, force: false)
                # We don't re-generate if the xunit-processed files were cached
                return if !force && File.file?(xunit_output)

                # We only check whether there are xml files in the
                # package's test dir. That's the only check we do ... if
                # the XML files are not JUnit, we'll finish with an empty
                # xunit html file
                Dir.enum_for(:glob, File.join(results_dir, '*.xml'))
                   .first
            end

            # Process the package's test results with xunit-viewer
            #
            # @param [String] xunit_viewer path to xunit-viewer
            # @param [Boolean] force re-generation of the xunit-viewer output. If
            #   false, packages that already have a xunit-viewer output will be skipped
            def process_test_results_xunit(force: false, xunit_viewer: 'xunit-viewer')
                consolidated_report['packages'].each_value do |info|
                    next unless info['test']
                    next unless (results_dir = info['test']['target_dir'])

                    xunit_output = "#{results_dir}.html"
                    next unless need_xunit_processing?(results_dir, xunit_output,
                                                       force: force)

                    success = system(xunit_viewer,
                                     "--results=#{results_dir}",
                                     "--output=#{xunit_output}")
                    unless success
                        Autoproj.warn 'xunit-viewer conversion failed '\
                                      "for '#{results_dir}'"
                    end
                end
            end

            # Post-processing of test results
            def process_test_results(force: false, xunit_viewer: 'xunit-viewer')
                process_test_results_xunit(force: force, xunit_viewer: xunit_viewer)
            end

            # Build a report in a given directory
            #
            # The method itself will not archive the directory, only gather the
            # information in a consistent way
            def create_report(dir)
                initialize_and_load
                finalize_setup([], non_imported_packages: :ignore)

                report = consolidated_report
                FileUtils.mkdir_p dir
                File.open(File.join(dir, 'report.json'), 'w') do |io|
                    JSON.dump(report, io)
                end

                installation_manifest = InstallationManifest
                                        .from_workspace_root(@ws.root_dir)
                logs = File.join(dir, 'logs')

                # Pre-create the logs, or cp_r will have a different behavior
                # if the directory exists or not
                FileUtils.mkdir_p logs
                installation_manifest.each_package do |pkg|
                    glob = Dir.glob(File.join(pkg.logdir, '*'))
                    FileUtils.cp_r(glob, logs) if File.directory?(pkg.logdir)
                end
            end

            def package_cache_path(dir, pkg, fingerprint: nil, memo: {})
                fingerprint ||= pkg.fingerprint(memo: memo)
                File.join(dir, pkg.name, fingerprint)
            end

            def package_cache_state(dir, pkg, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)

                {
                    'path' => path,
                    'cached' => File.file?(path),
                    'metadata' => File.file?("#{path}.json"),
                    'fingerprint' => fingerprint
                }
            end

            def pull_package_from_cache(dir, pkg, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)
                return [false, fingerprint, {}] unless File.file?(path)

                metadata_path = "#{path}.json"
                metadata =
                    if File.file?(metadata_path)
                        JSON.parse(File.read(metadata_path))
                    else
                        {}
                    end

                # Do not pull packages for which we should run tests
                tests_enabled = pkg.test_utility.enabled?
                tests_invoked = metadata['test'] && metadata['test']['invoked']
                return [false, fingerprint, metadata] if tests_enabled && !tests_invoked

                FileUtils.mkdir_p pkg.prefix
                result = system('tar', 'xzf', path, chdir: pkg.prefix, out: '/dev/null')
                raise "tar failed when pulling cache file for #{pkg.name}" unless result

                [true, fingerprint, metadata]
            end

            def push_package_to_cache(dir, pkg, metadata, force: false, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)
                temppath = "#{path}.#{Process.pid}.#{rand(256)}"

                FileUtils.mkdir_p File.dirname(path)
                if force || !File.file?("#{path}.json")
                    File.open(temppath, 'w') { |io| JSON.dump(metadata, io) }
                    FileUtils.mv temppath, "#{path}.json"
                end

                return [false, fingerprint] if !force && File.file?(path)

                result = system('tar', 'czf', temppath, '.',
                                chdir: pkg.prefix, out: '/dev/null')
                raise "tar failed when pushing cache file for #{pkg.name}" unless result

                FileUtils.mv temppath, path
                [true, fingerprint]
            end

            def load_built_flags
                path = @ws.build_report_path
                return {} unless File.file?(path)

                report = JSON.parse(File.read(path))
                report['build_report']['packages']
                    .each_with_object({}) do |pkg_report, h|
                        h[pkg_report['name']] = pkg_report['built']
                    end
            end

            def load_report(path, root_name, default: { 'packages' => {} })
                return default unless File.file?(path)

                JSON.parse(File.read(path)).fetch(root_name)
            end

            def consolidated_report
                # NOTE: keys must match PHASES
                new_reports = {
                    'import' => @ws.import_report_path,
                    'build' => @ws.build_report_path,
                    'test' => @ws.utility_report_path('test')
                }

                # We start with the cached info (if any) and override with
                # information from the other phase reports
                cache_report_path = File.join(@ws.root_dir, 'cache-pull.json')
                result = load_report(cache_report_path, 'cache_pull_report')['packages']
                result.delete_if do |_name, info|
                    next(true) unless info.delete('cached')

                    PHASES.each do |phase_name|
                        if (phase_info = info[phase_name])
                            phase_info['cached'] = true
                        end
                    end
                    false
                end

                new_reports.each do |phase_name, path|
                    report = load_report(path, "#{phase_name}_report")
                    report['packages'].each do |pkg_name, pkg_info|
                        result[pkg_name] ||= {}
                        if pkg_info['invoked']
                            result[pkg_name][phase_name] = pkg_info.merge(
                                'cached' => false,
                                'timestamp' => report['timestamp']
                            )
                        end
                    end
                end
                { 'packages' => result }
            end
        end
    end
end
