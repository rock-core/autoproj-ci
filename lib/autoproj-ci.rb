# frozen_string_literal: true

require 'autoproj/cli/main_ci'

module Autoproj
    module CLI
        # Toplevel CLI interface from Autoproj
        class Main
            desc 'ci', 'subcommands tuned for usage in CI environments'
            subcommand 'ci', Autoproj::CLI::MainCI
        end
    end
end
