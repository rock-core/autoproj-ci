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
            def resolve_packages
                initialize_and_load
                source_packages, * = finalize_setup(
                    [], non_imported_packages: :ignore)
                source_packages.map do |pkg_name|
                    ws.manifest.find_autobuild_package(pkg_name)
                end
            end

            def cache_pull(dir, ignore: [], silent: true)
                packages = resolve_packages

                memo   = Hash.new
                results = packages.each_with_object({}) do |pkg, h|
                    if ignore.include?(pkg.name)
                        fingerprint = pkg.fingerprint(memo: memo)
                        h[pkg.name] = {
                            'cached' => false,
                            'fingerprint' => fingerprint
                        }
                        next
                    end

                    state, fingerprint, metadata = pull_package_from_cache(dir, pkg, memo: memo)
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

            def cache_push(dir, force: [], silent: true)
                packages = resolve_packages
                metadata = consolidated_report['packages']

                memo   = Hash.new
                results = packages.each_with_object({}) do |pkg, h|
                    next unless (pkg_metadata = metadata[pkg.name])
                    next unless pkg_metadata['build']
                    next unless pkg_metadata['build']['success']
                    pkg_metadata.delete('cached')

                    state, fingerprint = push_package_to_cache(
                        dir, pkg, pkg_metadata,
                        force: force.include?(pkg.name), memo: memo)
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

                installation_manifest = InstallationManifest.
                    from_workspace_root(@ws.root_dir)
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

            def pull_package_from_cache(dir, pkg, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)
                unless File.file?(path)
                    return [false, fingerprint, {}]
                end

                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)

                metadata_path = "#{path}.yml"
                metadata = YAML.load(File.read(metadata_path)) if File.file?(metadata_path)
                # Upgrade from caches that did not have metadata
                metadata ||= {}

                FileUtils.mkdir_p pkg.prefix
                result = system("tar", "xzf", path, chdir: pkg.prefix, out: '/dev/null')
                unless result
                    raise "tar failed when pulling cache file for #{pkg.name}"
                end
                [true, pkg.fingerprint(memo: memo), metadata]
            end

            def push_package_to_cache(dir, pkg, metadata, force: false, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)
                temppath = "#{path}.#{Process.pid}.#{rand(256)}"

                FileUtils.mkdir_p File.dirname(path)
                if force || !File.file?("#{path}.yml")
                    File.open(temppath, 'w') { |io| YAML.dump(metadata, io) }
                    FileUtils.mv temppath, "#{path}.yml"
                end

                if !force && File.file?(path)
                    return [false, fingerprint]
                end

                result = system("tar", "czf", temppath, ".",
                    chdir: pkg.prefix, out: '/dev/null')
                unless result
                    raise "tar failed when pushing cache file for #{pkg.name}"
                end
                FileUtils.mv temppath, path

                [true, fingerprint]
            end

            def load_built_flags
                path = @ws.build_report_path
                return {} unless File.file?(path)

                report = JSON.load(File.read(path))
                report['build_report']['packages'].
                    each_with_object({}) do |pkg_report, h|
                        h[pkg_report['name']] = pkg_report['built']
                    end
            end

            def load_report(path, root_name, default: { 'packages' => {} })
                return default unless File.file?(path)
                JSON.load(File.read(path)).fetch(root_name)
            end

            def consolidated_report
                new_reports = {
                    'import' => @ws.import_report_path,
                    'build' => @ws.build_report_path,
                    'test' => @ws.utility_report_path('test')
                }

                # We start with the cached info (if any) and override with
                # information from the other phase reports
                cache_report_path = File.join(@ws.root_dir, 'cache-pull.json')
                result = load_report(cache_report_path, 'cache_pull_report')['packages']

                new_reports.each do |phase_name, path|
                    report = load_report(path, "#{phase_name}_report")
                    packages = report['packages']
                    timestamp = report['timestamp']

                    report['packages'].each do |pkg_name, pkg_info|
                        result[pkg_name] ||= { 'cached' => false }
                        result[pkg_name][phase_name] = pkg_info.merge(
                            'timestamp' => report['timestamp']
                        )
                    end
                end
                { 'packages' => result }
            end
        end
    end
end

