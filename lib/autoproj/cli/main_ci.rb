# frozen_string_literal: true

require "autoproj"
require "autoproj/cli/standalone_ci"

module Autoproj
    module CLI
        # CLI interface for autoproj-ci
        class MainCI < StandaloneCI
            desc "build [ARGS]", "Just like autoproj build, but can use a build cache"
            option :cache, type: "string",
                           desc: "path to the build cache"
            option :cache_ignore, type: :array, default: [],
                                  desc: "list of packages to not pull from cache"
            option :report, type: "string", default: "cache-pull.json",
                            desc: "a file which describes what has been pulled"
            def build(*args)
                if (cache = options.delete(:cache))
                    cache = File.expand_path(cache)
                    require "autoproj/cli/base"
                    Autoproj::CLI::Base.validate_options(args, options)
                    results = cache_pull(cache, ignore: options.delete(:cache_ignore))
                    pulled_packages = results
                                      .map { |name, pkg| name if pkg["cached"] }
                                      .compact
                    not_args = ["--not", *pulled_packages] unless pulled_packages.empty?
                end

                args << "--progress=#{options[:progress] ? 't' : 'f'}"
                args << "--color=#{options[:color] ? 't' : 'f'}"
                Process.exec(Gem.ruby, $PROGRAM_NAME, "build",
                             "--interactive=f", *args, *not_args)
            end

            desc "test [ARGS]", "Like autoproj test, but selects only packages "\
                                "that have been built"
            option :autoproj, desc: "path to autoproj", type: :string, default: nil
            def test(*args)
                require "autoproj/cli/ci"
                cli = CI.new
                cli.validate_options([], options.dup)
                report = cli.consolidated_report

                built_packages = report["packages"].find_all do |_name, info|
                    info["build"] && !info["build"]["cached"] && info["build"]["success"]
                end
                return if built_packages.empty?

                built_package_names = built_packages.map(&:first)
                program_name = options[:autoproj] || $PROGRAM_NAME
                Process.exec(Gem.ruby, program_name, "test",
                             "exec", "--interactive=f", *args, *built_package_names)
            end

            desc "process-test-results [ARGS]",
                 "Process test output (assumed to be in JUnit XML) through xunit-viewer"
            option :force, desc: "re-generates existing output", default: false
            option :xunit_viewer, desc: "path to xunit-viewer", default: "xunit-viewer"
            def process_test_results
                require "autoproj/cli/ci"
                cli = CI.new
                cli.validate_options([], options.dup)
                cli.process_test_results(
                    force: options[:force],
                    xunit_viewer: options[:xunit_viewer]
                )
            end

            desc "status DIR", "Display the cache status"
            option :cache, type: "string",
                           desc: "path to the build cache"
            def status(dir)
                cache = File.expand_path(dir)
                require "autoproj/cli/ci"
                cli = CI.new
                cli.validate_options(dir, options)
                results = cli.cache_state(cache)
                results.keys.sort.each do |name|
                    status = results[name]
                    fields = []
                    fields <<
                        if status["cached"]
                            Autoproj.color("cache hit", :green)
                        else
                            Autoproj.color("cache miss", :red)
                        end
                    fields << "fingerprint=#{status['fingerprint']}"
                    puts "#{name}: #{fields.join(', ')}"
                end
            end

            desc "cache-pull CACHE_DIR",
                 "This command gets relevant artifacts from a build cache and "\
                 "populates the current workspace's prefix with them. It is meant "\
                 "to be executed after a full checkout of the workspace"
            option :report, type: "string", default: "cache-pull.json",
                            desc: "a file which describes what has been done"
            option :ignore, type: :array, default: [],
                            desc: "list of packages to not pull from cache"
            def cache_pull(dir, ignore: [])
                dir = File.expand_path(dir)

                require "autoproj/cli/ci"
                results = nil

                cli = CI.new
                _, options = cli.validate_options(dir, self.options)
                report = options.delete(:report)

                # options[:ignore] is not set if we call from another
                # command, e.g. build
                ignore += (options.delete(:ignore) || [])
                results = cli.cache_pull(*dir, ignore: ignore, **options)

                if report && !report.empty?
                    File.open(report, "w") do |io|
                        JSON.dump(
                            {
                                "cache_pull_report" => {
                                    "packages" => results
                                }
                            }, io
                        )
                    end
                end
                results
            end

            desc "cache-push CACHE_DIR",
                 "This command writes the packages successfully built in the last "\
                 "build to the given build cache, so that they can be reused with "\
                 "cache-pull"
            option :report, type: "string", default: "cache-push.json",
                            desc: "a file which describes what has been done"
            def cache_push(dir)
                dir = File.expand_path(dir)

                require "autoproj/cli/ci"
                cli = CI.new

                _, options = cli.validate_options(dir, self.options)
                report = options.delete(:report)

                results = cli.cache_push(dir, **options)

                return unless report && !report.empty?

                File.open(report, "w") do |io|
                    JSON.dump(
                        {
                            "cache_push_report" => {
                                "packages" => results
                            }
                        }, io
                    )
                end
            end

            desc "build-cache-cleanup CACHE_DIR",
                 "Remove the oldest entries in the cache until "\
                 "it is under a given size limit"
            option :max_size,
                   type: "numeric", default: 10,
                   desc: "approximate target size limit (in GB, defaults to 10)"
            def build_cache_cleanup(dir)
                dir = File.expand_path(dir)

                require "autoproj/cli/ci"
                cli = CI.new

                _, options = cli.validate_options(dir, self.options)
                cli.cleanup_build_cache(dir, options[:max_size] * 1_000_000_000)
            end

            desc "create-report PATH",
                 "create a directory containing all the information about this "\
                 "build, such as cache information (from cache-pull), Autoproj's "\
                 "build report and installation manifest, and the package's logfiles"
            def create_report(path)
                path = File.expand_path(path)

                require "autoproj/cli/ci"
                cli = CI.new
                args, options = cli.validate_options(path, self.options)
                cli.create_report(*args, **options)
            end

            desc "result PATH",
                 "exit with a code based on the results stored in the given "\
                 "report dir, created by build-report"
            option :exit_code,
                   type: :numeric, default: 1,
                   desc: "the exit code to use on failure"
            def result(path)
                path = File.expand_path(path)
                report = JSON.parse(File.read(File.join(path, "report.json")))

                require "autoproj/cli/ci"
                cli = CI.new
                failures = cli.packages_states(report)
                              .find_all(&:failure?)
                              .sort_by(&:name)

                if failures.empty?
                    puts "All packages built and tested successfully"
                    exit 0
                end

                failures.each do |pkg_state|
                    puts "#{pkg_state.name} failed during #{pkg_state.phase} "\
                            "phase#{' (from cache)' if pkg_state.cached?}"
                end
                exit options[:exit_code]
            end
        end
    end
end
