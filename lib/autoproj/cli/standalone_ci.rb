# frozen_string_literal: true

require 'erb'
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
                    prepare_workspace(config_dir, dir, options[:workspace])
                end

                output = File.expand_path(output)
                unless system('tar', 'czf', output, '.', chdir: dir)
                    raise "failed to create #{output}"
                end
            ensure
                FileUtils.rm_rf(dir) if dir && File.directory?(dir)
            end

            no_commands do
                def prepare_workspace(config_dir, output_dir, workspace_dir)
                    FileUtils.mkdir_p File.join(output_dir, workspace_dir, '.autoproj')

                    if File.file?(envsh = File.join(config_dir, 'env.sh'))
                        filter_envsh(envsh, output_dir, workspace_dir)
                        generate_autoproj_stub(output_dir, workspace_dir)
                    end

                    if File.file?(file = File.join(config_dir, 'source.yml'))
                        FileUtils.cp(
                            file, File.join(output_dir, workspace_dir, '.autoproj')
                        )
                    end

                    if File.file?(file = File.join(config_dir, 'installation-manifest'))
                        FileUtils.cp(
                            file,
                            File.join(output_dir, workspace_dir, 'installation-manifest')
                        )
                    end
                end

                AUTOPROJ_STUB_PATH = File.join(__dir__, 'autoproj-stub.sh.erb').freeze

                def filter_envsh(source_path, output_dir, workspace_dir)
                    filtered = File.readlines(source_path)
                                   .find_all { |l| !/^(source|\.)/.match?(l) }
                    File.open(File.join(output_dir, workspace_dir, 'env.sh'), 'w') do |io|
                        io.write(filtered.join)
                    end
                end

                def generate_autoproj_stub(output_dir, workspace_dir)
                    dot_autoproj = File.join(output_dir, workspace_dir, '.autoproj')
                    autoproj_path = File.join(dot_autoproj, 'autoproj')

                    erb = ERB.new(File.read(AUTOPROJ_STUB_PATH))
                    erb.location = [AUTOPROJ_STUB_PATH, 0]
                    File.open(autoproj_path, 'w') do |io|
                        io.write erb.result_with_hash(workspace_dir: "/#{workspace_dir}")
                    end
                    FileUtils.chmod 0o755, autoproj_path
                end
            end
        end
    end
end
