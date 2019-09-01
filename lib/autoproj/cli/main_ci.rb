require 'autoproj'

module Autoproj
    module CLI
        # CLI interface for autoproj-ci
        class MainCI < Thor
            desc 'build [ARGS]', "Just like autoproj build, but can use a build cache"
            option :cache, type: 'string',
                desc: 'path to the build cache'
            option :cache_ignore, type: :array, default: [],
                desc: 'list of packages to not pull from cache'
            option :report, type: 'string', default: 'cache-pull.json',
                desc: 'a file which describes what has been pulled'
            def build(*args)
                if (cache = options.delete(:cache))
                    cache = File.expand_path(cache)
                    results = cache_pull(cache, ignore: options.delete(:cache_ignore))
                    pulled_packages = results.
                        map { |name, pkg| name if pkg['cached'] }.
                        compact
                    not_args = ['--not', *pulled_packages] unless pulled_packages.empty?
                end

                Process.exec(Gem.ruby, $PROGRAM_NAME, 'build', "--interactive=f", *args, *not_args)
            end

            desc 'cache-pull CACHE_DIR',
                "This command gets relevant artifacts from a build cache and "\
                "populates the current workspace's prefix with them. It is meant "\
                "to be executed after a full checkout of the workspace"
            option :report, type: 'string', default: 'cache-pull.json',
                desc: 'a file which describes what has been done'
            option :ignore, type: :array, default: [],
                desc: 'list of packages to not pull from cache'
            def cache_pull(dir, ignore: [])
                dir = File.expand_path(dir)

                require 'autoproj/cli/ci'
                results = nil
                Autoproj.report(silent: true) do
                    cli = CI.new
                    args, options = cli.validate_options(dir, self.options)
                    report = options.delete(:report)

                    # options[:ignore] is not set if we call from another
                    # command, e.g. build
                    ignore = ignore + (options.delete(:ignore) || [])
                    results = cli.cache_pull(*dir, silent: false, ignore: ignore, **options)

                    if report && !report.empty?
                        File.open(report, 'w') do |io|
                            JSON.dump(results, io)
                        end
                    end
                end
                results
            end

            desc 'cache-push CACHE_DIR',
                "This command writes the packages successfully built in the last "\
                "build to the given build cache, so that they can be reused with "\
                "cache-pull"
            option :report, type: 'string', default: 'cache-push.json',
                desc: 'a file which describes what has been done'
            option :force, type: :array, default: [],
                desc: 'push these packages even if it appears a cache entry exists for them'
            def cache_push(dir)
                dir = File.expand_path(dir)

                require 'autoproj/cli/ci'
                Autoproj.report(silent: true) do
                    cli = CI.new

                    args, options = cli.validate_options(dir, self.options)
                    report = options.delete(:report)

                    results = cli.cache_push(*dir, silent: false, **options)

                    if report && !report.empty?
                        File.open(report, 'w') do |io|
                            JSON.dump(results, io)
                        end
                    end
                end
            end

            desc "build-report PATH",
                "Create a tarball containing all the information about this "\
                "build, such as cache information (from cache-pull), Autoproj\'s "\
                "build report and installation manifest, and the package\'s logfiles"
            def build_report(path)
                path = File.expand_path(path)

                require 'autoproj/cli/ci'
                Autoproj.report(silent: true) do
                    cli = CI.new
                    args, options = cli.validate_options(path, self.options)
                    cli.build_report(*args, **options)
                end
            end
        end
    end
end

