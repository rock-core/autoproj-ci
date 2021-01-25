# frozen_string_literal: true

require "erb"
require "thor"

require "autoproj"
require "autoproj/ci/rebuild"

module Autoproj
    module CLI
        # CI-related commands that can be executed without an Autoproj installation
        class StandaloneCI < Thor
            desc "rebuild-root CONFIG_DIR CACHE_ROOT OUTPUT",
                 "creates a compressed tarball containing the build products of a "\
                 "finished build, pulled from build cache"
            option "workspace",
                   desc: "if given, setup a minimal workspace-like structure to "\
                         "support execution in the given path",
                   type: :string, default: nil
            def rebuild_root(config_dir, cache_root, output)
                dir = Dir.mktmpdir
                Autoproj::CI::Rebuild.prepare_synthetic_buildroot(
                    File.join(config_dir, "installation-manifest"),
                    File.join(config_dir, "versions.yml"),
                    cache_root,
                    dir
                )

                if options[:workspace]
                    prepare_workspace(config_dir, dir, options[:workspace])
                end

                output = File.expand_path(output)
                unless system("tar", "caf", output, "--owner=root", "--group=root",
                              ".", chdir: dir)
                    raise "failed to create #{output}"
                end
            ensure
                FileUtils.rm_rf(dir) if dir && File.directory?(dir)
            end

            desc "dpkg-filter-status STATUS_PATH [RULES]",
                 "outputs the list of APT packages to install based on a dpkg status "\
                 'file and a set of inclusion/exclusion rules of the form "+ pattern" '\
                 'and "- pattern"'
            option :orig, desc: "a status file whose installed packages are removed",
                          type: :string
            option :file, desc: "read the rules from a file",
                          type: :string
            def dpkg_filter_status(status_path, *rules)
                rules += File.readlines(options[:file]).map(&:strip) if options[:file]
                rules = rules.map do |line|
                    next if line.empty? || line.start_with?("#")

                    parse_rule(line)
                end

                packages = Autoproj::CI::Rebuild.dpkg_create_package_install(
                    status_path, rules, orig: options[:orig]
                )
                puts packages.join("\n")
            end

            AUTOPROJ_STUB_PATH = File.join(__dir__, "autoproj-stub.sh.erb").freeze

            no_commands do # rubocop:disable Metrics/BlockLength
                def parse_rule(line)
                    unless (m = /^([+-])\s+(.*)/.match(line))
                        raise ArgumentError, "invalid rule line '#{line}'"
                    end

                    mode = (m[1] == "+")
                    begin
                        [mode, Regexp.new(m[2])]
                    rescue RegexpError => e
                        raise ArgumentError, "invalid regexp in '#{line}': #{e}"
                    end
                end

                def prepare_workspace(config_dir, output_dir, workspace_dir)
                    FileUtils.mkdir_p File.join(output_dir, workspace_dir, ".autoproj")

                    if File.file?(envsh = File.join(config_dir, "env.sh"))
                        filter_envsh(envsh, output_dir, workspace_dir)
                        generate_autoproj_stub(output_dir, workspace_dir)
                    end

                    if File.file?(file = File.join(config_dir, "source.yml"))
                        FileUtils.cp(
                            file, File.join(output_dir, workspace_dir, ".autoproj")
                        )
                    end

                    if File.file?(file = File.join(config_dir, "installation-manifest"))
                        FileUtils.cp(
                            file,
                            File.join(output_dir, workspace_dir, "installation-manifest")
                        )
                    end

                    nil
                end

                def filter_envsh(source_path, output_dir, workspace_dir)
                    filtered = File.readlines(source_path)
                                   .find_all { |l| !/^(source|\.)/.match?(l) }
                    File.open(File.join(output_dir, workspace_dir, "env.sh"), "w") do |io|
                        io.write(filtered.join)
                    end
                end

                def generate_autoproj_stub(output_dir, workspace_dir)
                    dot_autoproj = File.join(output_dir, workspace_dir, ".autoproj")
                    FileUtils.mkdir File.join(dot_autoproj, "bin")
                    autoproj_path = File.join(dot_autoproj, "bin", "autoproj")

                    erb = ERB.new(File.read(AUTOPROJ_STUB_PATH))
                    erb.location = [AUTOPROJ_STUB_PATH, 0]
                    File.open(autoproj_path, "w") do |io|
                        io.write erb.result_with_hash(workspace_dir: "/#{workspace_dir}")
                    end
                    FileUtils.chmod 0o755, autoproj_path
                end
            end
        end
    end
end
