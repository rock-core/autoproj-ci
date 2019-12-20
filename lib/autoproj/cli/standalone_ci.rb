# frozen_string_literal: true

require 'thor'
require 'autoproj'
require 'autoproj/ci/rebuild'

module Autoproj
    module CLI
        # CI-related commands that can be executed without an Autoproj installation
        class StandaloneCI < Thor
            desc 'rebuild-root CONFIG_DIR CACHE_ROOT OUTPUT',
                 'creates a compressed tarball containing the build products of a '\
                 'finished build, pulled from build cache'
            option 'workspace',
                   desc: 'if given, setup a minimal workspace-like structure to '\
                         'support execution in the given path',
                   type: :string, default: nil
            def rebuild_root(config_dir, cache_root, output)
                dir = Dir.mktmpdir
                Autoproj::CI::Rebuild.prepare_synthetic_buildroot(
                    File.join(config_dir, 'installation-manifest'),
                    File.join(config_dir, 'versions.yml'),
                    cache_root,
                    dir
                )

                if options[:workspace]
                    prepare_workspace(config_dir, File.join(dir, options[:workspace]))
                end

                output = File.expand_path(output)
                unless system('tar', 'czf', output, '.', chdir: dir)
                    raise "failed to create #{output}"
                end
            ensure
                FileUtils.rm_rf(dir) if dir && File.directory?(dir)
            end
        end
    end
end
