# frozen_string_literal: true
require "test_helper"
require "thor"
require "autoproj/cli/main_ci"

module Autoproj::CLI # rubocop:disable Style/ClassAndModuleChildren, Style/Documentation
    describe StandaloneCI do
        before do
            @fixtures_path = File.join(__dir__, "..", "ci", "fixtures", "rebuild")
            @cache_root = File.join(@fixtures_path, "cache")
        end

        describe "rebuild_root" do
            it "builds a tarball from the build info" do
                output = File.join(make_tmpdir, "output.tar.gz")

                StandaloneCI.start(["rebuild-root", @fixtures_path, @cache_root, output])

                out = make_tmpdir
                system("tar", "xzf", output, chdir: out, out: "/dev/null")
                base_types_file = File.join(
                    out, "path", "to", "base", "types", "prefix", "base-types"
                )
                assert File.file?(base_types_file)
                iodrivers_base_file = File.join(
                    out, "path", "to", "drivers", "iodrivers_base",
                    "prefix", "drivers-iodrivers_base"
                )
                assert File.file?(iodrivers_base_file)
            end

            it "handles relative paths" do
                out_dir = make_tmpdir
                output = "output.tar.gz"
                Dir.chdir(out_dir) do
                    StandaloneCI.start(["rebuild-root", @fixtures_path, @cache_root, output])
                end
                assert File.file?(File.join(out_dir, output))
            end

            it "sets the file's owner and group to root" do
                output = File.join(make_tmpdir, "output.tar.gz")

                StandaloneCI.start(["rebuild-root", @fixtures_path, @cache_root, output])

                io = IO.popen(["tar", "xzf", output, "--to-command", "sh -c env"])
                _, status = Process.waitpid2(io.pid)
                flunk("listing UIDs for #{output} failed") unless status.success?

                lines = io.readlines.map(&:chomp)
                assert_equal ["TAR_UID=0"], lines.grep(/TAR_UID/).uniq
                assert_equal ["TAR_GID=0"], lines.grep(/TAR_GID/).uniq
            end

            it "optionally prepares a workspace-like folder to provide with an execution environment" do
                output = File.join(make_tmpdir, "output.tar.gz")

                StandaloneCI.start(["rebuild-root", @fixtures_path, @cache_root, output,
                                    "--workspace", "ws"])

                out = make_tmpdir
                system("tar", "xzf", output, chdir: out, out: "/dev/null")
                assert_equal "export ENV=value",
                             File.read(File.join(out, "ws", "env.sh")).strip

                # Unfortunately, we can't chroot from the user.
                # Just check that the source and exec lines point to the right files
                autoproj_exec =
                    File.readlines(File.join(out, "ws", ".autoproj", "bin", "autoproj"))
                        .map(&:strip)
                assert(autoproj_exec.find { |l| l == ". /ws/env.sh" })
            end
        end

        describe "dpkg-filter-status" do
            before do
                @status_path = File.join(@fixtures_path, "dpkg-status")
                @orig_status_path = File.join(@fixtures_path, "dpkg-status.orig")
            end

            it "returns the list of installed packages when there are no rules" do
                out, = capture_io do
                    StandaloneCI.start(["dpkg-filter-status", @status_path])
                end
                assert_equal %w[pkg1 pkg2 pkg1-dev pkg2-dev].join("\n"), out.chomp
            end

            it "allows to filter out the installed packages from another status file" do
                out, = capture_io do
                    StandaloneCI.start(["dpkg-filter-status", @status_path,
                                        "--orig", @orig_status_path])
                end
                assert_equal %w[pkg1-dev pkg2-dev].join("\n"), out.chomp
            end

            it "excludes packages that match an exclusion rule" do
                out, = capture_io do
                    StandaloneCI.start(["dpkg-filter-status", @status_path, "- -dev$"])
                end
                assert_equal %w[pkg1 pkg2].join("\n"), out.chomp
            end

            it "uses the first matching rule to decide on a package" do
                out, = capture_io do
                    StandaloneCI.start(["dpkg-filter-status", @status_path,
                                        "+ pkg1", "- -dev$"])
                end
                assert_equal %w[pkg1 pkg2 pkg1-dev].join("\n"), out.chomp
            end

            it "can read rules from a file" do
                Tempfile.open("rules") do |io|
                    io.puts "+ pkg1"
                    io.puts "- -dev$"
                    io.flush

                    out, = capture_io do
                        StandaloneCI.start(["dpkg-filter-status", @status_path,
                                            "--file", io.path])
                    end
                    assert_equal %w[pkg1 pkg2 pkg1-dev].join("\n"), out.chomp
                end
            end
        end
    end
end
