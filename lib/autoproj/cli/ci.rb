require 'autoproj/cli/inspection_tool'

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

            def cache_pull(dir)
                packages = resolve_packages

                memo   = Hash.new
                results = packages.each_with_object({}) do |pkg, h|
                    state, fingerprint = pull_package_from_cache(dir, pkg, memo: memo)

                    h[pkg.name] = {
                        'cached' => state,
                        'fingerprint' => fingerprint
                    }
                end

                results
            end

            def cache_push(dir)
                packages = resolve_packages

                built = load_built_flags

                memo   = Hash.new
                results = packages.each_with_object({}) do |pkg, h|
                    next unless built[pkg.name]

                    state, fingerprint = push_package_to_cache(dir, pkg, memo: memo)


                    h[pkg.name] = {
                        'updated' => state,
                        'fingerprint' => fingerprint
                    }
                end

                results
            end

            def package_cache_path(dir, pkg, fingerprint: nil, memo: {})
                fingerprint ||= pkg.fingerprint(memo: memo)
                File.join(dir, pkg.name, fingerprint)
            end

            def pull_package_from_cache(dir, pkg, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)
                return [false, fingerprint] unless File.file?(path)

                FileUtils.mkdir_p pkg.prefix
                result = system("tar", "xzf", path, chdir: pkg.prefix, out: '/dev/null')
                unless result
                    raise "tar failed when pulling cache file for #{pkg.name}"
                end
                [true, pkg.fingerprint(memo: memo)]
            end

            def push_package_to_cache(dir, pkg, memo: {})
                fingerprint = pkg.fingerprint(memo: memo)
                path = package_cache_path(dir, pkg, fingerprint: fingerprint, memo: memo)
                return [false, fingerprint] if File.file?(path)

                temppath = "#{path}.#{Process.pid}.#{rand(256)}"
                FileUtils.mkdir_p File.dirname(path)
                result = system("tar", "czf", temppath, ".",
                    chdir: pkg.prefix, out: '/dev/null')
                unless result
                    raise "tar failed when pushing cache file for #{pkg.name}"
                end

                FileUtils.mv temppath, path
                [true, fingerprint]
            end

            def load_built_flags
                report = JSON.load(File.read(@ws.build_report_path))
                report['build_report']['packages'].
                    each_with_object({}) do |pkg_report, h|
                        h[pkg_report['name']] = pkg_report['built']
                    end
            end
        end
    end
end

