# frozen_string_literal: true

require "autoproj/cli/inspection_tool"
require "tmpdir"

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
                        state = state.merge("cached" => false, "metadata" => false)
                    end

                    h[pkg.name] = state
                end
            end

            def cache_pull(dir, ignore: [])
                packages = resolve_packages

                memo = {}
                results = packages.each_with_object({}) do |pkg, h|
                    if ignore.include?(pkg.name)
                        pkg.message "%s: ignored by command line"
                        fingerprint = pkg.fingerprint(memo: memo)
                        h[pkg.name] = {
                            "cached" => false,
                            "fingerprint" => fingerprint
                        }
                        next
                    end

                    state, fingerprint, metadata =
                        pull_package_from_cache(dir, pkg, memo: memo)
                    if state
                        pkg.message "%s: pulled #{fingerprint}", :green
                    else
                        pkg.message "%s: #{fingerprint} not in cache, "\
                                    "or not pulled from cache"
                    end

                    h[pkg.name] = metadata.merge(
                        "cached" => state,
                        "fingerprint" => fingerprint
                    )
                end

                hit = results.count { |_, info| info["cached"] }
                Autoproj.message "#{hit} hits, #{results.size - hit} misses"

                results
            end

            def cache_push(dir)
                packages = resolve_packages
                metadata = consolidated_report["packages"]

                memo = {}
                results = packages.each_with_object({}) do |pkg, h|
                    if !(pkg_metadata = metadata[pkg.name])
                        pkg.message "%s: no metadata in build report", :magenta
                        next
                    elsif !(build_info = pkg_metadata["build"])
                        pkg.message "%s: no build info in build report", :magenta
                        next
                    elsif build_info["cached"]
                        pkg.message "%s: was pulled from cache, not pushing"
                        next
                    elsif !build_info["success"]
                        pkg.message "%s: build failed, not pushing", :magenta
                        next
                    end

                    # Remove cached flags before saving
                    pkg_metadata = pkg_metadata.dup
                    PHASES.each do |phase_name|
                        pkg_metadata[phase_name]&.delete("cached")
                    end

                    state, fingerprint = push_package_to_cache(
                        dir, pkg, pkg_metadata, force: true, memo: memo
                    )
                    if state
                        pkg.message "%s: pushed #{fingerprint}", :green
                    else
                        pkg.message "%s: #{fingerprint} already in cache"
                    end

                    h[pkg.name] = {
                        "updated" => state,
                        "fingerprint" => fingerprint
                    }
                end

                hit = results.count { |_, info| info["updated"] }
                Autoproj.message "#{hit} updated packages, #{results.size - hit} "\
                                 "reused entries"

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
                Dir.enum_for(:glob, File.join(results_dir, "*.xml"))
                   .first
            end

            # Process the package's test results with xunit-viewer
            #
            # @param [String] xunit_viewer path to xunit-viewer
            # @param [Boolean] force re-generation of the xunit-viewer output. If
            #   false, packages that already have a xunit-viewer output will be skipped
            def process_test_results_xunit(force: false, xunit_viewer: "xunit-viewer")
                consolidated_report["packages"].each_value do |info|
                    next unless info["test"]
                    next unless (results_dir = info["test"]["target_dir"])

                    xunit_output = "#{results_dir}.html"
                    next unless need_xunit_processing?(results_dir, xunit_output,
                                                       force: force)

                    success = system(xunit_viewer,
                                     "--results=#{results_dir}",
                                     "--output=#{xunit_output}")
                    unless success
                        Autoproj.warn "xunit-viewer conversion failed "\
                                      "for '#{results_dir}'"
                    end
                end
            end

            # Post-processing of test results
            def process_test_results(force: false, xunit_viewer: "xunit-viewer")
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
                FileUtils.mkdir_p(dir)
                File.open(File.join(dir, "report.json"), "w") do |io|
                    JSON.dump(report, io)
                end

                installation_manifest = InstallationManifest
                                        .from_workspace_root(@ws.root_dir)
                logs = File.join(dir, "logs")

                # Pre-create the logs, or cp_r will have a different behavior
                # if the directory exists or not
                FileUtils.mkdir_p(logs)
                installation_manifest.each_package do |pkg|
                    glob = Dir.glob(File.join(pkg.logdir, "*"))
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
                    "path" => path,
                    "cached" => File.file?(path),
                    "metadata" => File.file?("#{path}.json"),
                    "fingerprint" => fingerprint
                }
            end

            class CorruptedCacheEntry < RuntimeError
            end

            def pull_package_from_cache(dir, pkg, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)
                return [false, fingerprint, {}] unless File.file?(path)

                metadata_path = "#{path}.json"
                metadata = load_cached_metadata(pkg, metadata_path)

                # Do not pull packages for which we should run tests
                tests_enabled = pkg.test_utility.enabled?
                tests_invoked = metadata["test"] && metadata["test"]["invoked"]
                if tests_enabled && !tests_invoked
                    pkg.message "%s: has tests that have never "\
                                "been invoked, not pulling from cache"
                    return [false, fingerprint, {}]
                end

                extract_dir_tarball(pkg, pkg.prefix, path)
                if File.file?("#{path}.logs")
                    extract_dir_tarball(pkg, pkg.logdir, "#{path}.logs")
                end

                begin
                    FileUtils.touch metadata_path, nocreate: true
                    FileUtils.touch path, nocreate: true
                rescue Errno::ENOENT # rubocop:disable Lint/SuppressedException
                end
                [true, fingerprint, metadata]
            rescue CorruptedCacheEntry => e
                Autoproj.warn(
                    "cache entry for #{fingerprint} from #{pkg.name} seem corrupted, "\
                    "deleting: #{e.message}"
                )
                remove_cache_entry(dir, pkg, fingerprint)
                [false, fingerprint, {}]
            end

            def load_cached_metadata(pkg, metadata_path)
                return {} unless File.file?(metadata_path)

                JSON.parse(File.read(metadata_path))
            rescue JSON::ParserError
                raise CorruptedCacheEntry, "failed to load metadata for #{pkg.name}"
            end

            def remove_cache_entry(dir, pkg, fingerprint)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint)

                FileUtils.rm_f path
                FileUtils.rm_f "#{path}.json"
                FileUtils.rm_f "#{path}.logs"
            end

            def extract_dir_tarball(pkg, target_dir, path)
                FileUtils.mkdir_p target_dir
                return if system("tar", "xzf", path, chdir: target_dir, out: "/dev/null")

                raise CorruptedCacheEntry, "failed to uncompress #{path} for #{pkg.name}"
            end

            def push_package_to_cache(dir, pkg, metadata, force: false, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)

                FileUtils.mkdir_p(File.dirname(path))
                if force || !File.file?("#{path}.json")
                    temppath = "#{path}.#{Process.pid}.#{rand(256)}"
                    File.open(temppath, "w") { |io| JSON.dump(metadata, io) }
                    FileUtils.mv(temppath, "#{path}.json")
                end

                if !force && File.file?(path)
                    # Update modification time for the cleanup process
                    FileUtils.touch(path)
                    return [false, fingerprint]
                end

                create_dir_tarball(pkg, pkg.prefix, path)
                if File.directory?(pkg.logdir)
                    create_dir_tarball(pkg, pkg.logdir, "#{path}.logs")
                end
                [true, fingerprint]
            end

            def create_dir_tarball(pkg, source_dir, path)
                temppath = "#{path}.#{Process.pid}.#{rand(256)}"
                result = system("tar", "czf", temppath, ".",
                                chdir: source_dir, out: "/dev/null")
                unless result
                    raise "tar failed when caching #{source_dir} for #{pkg.name}"
                end

                FileUtils.mv(temppath, path)
            end

            def cleanup_build_cache(dir, size_limit)
                all_files = Find.enum_for(:find, dir).map do |path|
                    next unless File.file?(path) && File.file?("#{path}.json")

                    [path, File.stat(path)]
                end.compact

                total_size = all_files.map { |_, s| s.size }.sum
                lru = all_files.sort_by { |_, s| s.mtime }

                while total_size > size_limit
                    path, stat = lru.shift
                    Autoproj.message(
                        "removing #{path} (size=#{stat.size}, mtime=#{stat.mtime})"
                    )

                    FileUtils.rm_f path
                    FileUtils.rm_f "#{path}.json"
                    total_size -= stat.size
                end

                Autoproj.message format("current build cache size: %.1f GB",
                                        Float(total_size) / 1_000_000_000)
                total_size
            end

            def load_built_flags
                path = @ws.build_report_path
                return {} unless File.file?(path)

                report = JSON.parse(File.read(path))
                report["build_report"]["packages"]
                    .each_with_object({}) do |pkg_report, h|
                        h[pkg_report["name"]] = pkg_report["built"]
                    end
            end

            def load_report(path, root_name, default: { "packages" => {} })
                return default unless File.file?(path)

                JSON.parse(File.read(path)).fetch(root_name)
            end

            def consolidated_report
                # NOTE: keys must match PHASES
                new_reports = {
                    "import" => @ws.import_report_path,
                    "build" => @ws.build_report_path,
                    "test" => @ws.utility_report_path("test")
                }

                # We start with the cached info (if any) and override with
                # information from the other phase reports
                cache_report_path = File.join(@ws.root_dir, "cache-pull.json")
                result = load_report(cache_report_path, "cache_pull_report")["packages"]
                result.delete_if do |_name, info|
                    next true unless info.delete("cached")

                    PHASES.each do |phase_name|
                        if (phase_info = info[phase_name])
                            phase_info["cached"] = true
                        end
                    end
                    false
                end

                new_reports.each do |phase_name, path|
                    report = load_report(path, "#{phase_name}_report")
                    report["packages"].each do |pkg_name, pkg_info|
                        result[pkg_name] ||= {}
                        if pkg_info["invoked"]
                            result[pkg_name][phase_name] = pkg_info.merge(
                                "cached" => false,
                                "timestamp" => report["timestamp"]
                            )
                        end
                    end
                end
                { "packages" => result }
            end

            PHASE_INVERSE_ORDER = %w[test build import].freeze

            PACKAGE_SUCCESS = "success"
            PACKAGE_FAILURE = "failure"
            PACKAGE_SKIPPED = "skipped"
            PackageState = Struct.new :name, :phase, :state, :cached do
                def skipped?
                    state == PACKAGE_SKIPPED
                end

                def success?
                    state == PACKAGE_SUCCESS
                end

                def failure?
                    state == PACKAGE_FAILURE
                end

                def cached?
                    cached
                end
            end

            # Compute the set of failed packages that have been pulled from cache
            #
            # @param [Hash] the consolidated report as returned by {#consolidated_report}
            # @return [Array<Failure>]
            def packages_states(consolidated_report)
                consolidated_report["packages"].map do |name, phases|
                    main_phase_name = PHASE_INVERSE_ORDER.find do |phase_name|
                        phases[phase_name] && phases[phase_name]["invoked"]
                    end

                    if main_phase_name
                        main_phase = phases[main_phase_name]
                        state = main_phase["success"] ? PACKAGE_SUCCESS : PACKAGE_FAILURE
                        PackageState.new(name, main_phase_name,
                                         state, main_phase["cached"])
                    else
                        PackageState.new(name, nil, "skipped", false)
                    end
                end
            end
        end
    end
end
