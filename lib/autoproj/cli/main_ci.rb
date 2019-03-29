require 'autoproj'

module Autoproj
    module CLI
        # CLI interface for autoproj-ci
        class MainCI < Thor
            desc 'cache-pull CACHE_DIR',
                "This command gets relevant artifacts from a build cache and "\
                "populates the current workspace's prefix with them. It is meant "\
                "to be executed after a full checkout of the workspace"
            option :report, type: 'string', default: 'cache-pull.json',
                desc: 'a file which describes what has been done'
            def cache_pull(dir)
                dir = File.expand_path(dir)

                require 'autoproj/cli/ci'
                Autoproj.report(silent: true) do
                    cli = CI.new
                    args, options = cli.validate_options(dir, self.options)
                    report = options.delete(:report)

                    results = cli.cache_pull(*dir, silent: false, **options)
                end
            end

            desc 'cache-push CACHE_DIR',
                "This command writes the packages successfully built in the last "\
                "build to the given build cache, so that they can be reused with "\
                "cache-pull"
            option :report, type: 'string', default: 'cache-push.json',
                desc: 'a file which describes what has been done'
            def cache_push(dir)
                dir = File.expand_path(dir)

                require 'autoproj/cli/ci'
                Autoproj.report(silent: true) do
                    cli = CI.new

                    args, options = cli.validate_options(dir, self.options)
                    report = options.delete(:report)

                    results = cli.cache_push(*dir, silent: false, **options)
                end
            end
        end
    end
end

