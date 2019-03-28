module Autoproj
    module CLI
        # CLI interface for autoproj-ci
        class MainCI < Thor
            desc 'pull build results from a build cache'
            option :report, type: :String, default: 'cache-pull.json',
                desc: 'a file which describes what has been done'
            def cache_pull(dir)
                Autoproj.report(silent: true) do
                    cli = CI.new
                    args, options = cli.validate_options(dir, **options)
                    cli.cache_pull(*dir, **options)
                end
            end

            desc 'push build results to a build cache'
            option :report, type: :String, default: 'cache-push.json',
                desc: 'a file which describes what has been done'
            def cache_push(dir)
                Autoproj.report(silent: true) do
                    cli = CI.new
                    args, options = cli.validate_options(dir, **options)
                    cli.cache_push(*dir, **options)
                end
            end
        end
    end
end

