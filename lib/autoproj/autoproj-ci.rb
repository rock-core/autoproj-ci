require 'autoproj/cli/main_ci'

class Autoproj::CLI::Main
    desc 'ci', 'subcommands tuned for usage in CI environments'
    subcommand 'ci', Autoproj::CLI::MainCI
end