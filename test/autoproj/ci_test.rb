require "test_helper"
require 'rubygems/package'

module Autoproj::CLI
    describe CI do
        before do
            @ws = ws_create
            @archive_dir = make_tmpdir
            @prefix_dir = make_tmpdir

            @pkg = ws_define_package :cmake, "a"
            flexmock(@pkg.autobuild).
                should_receive(:fingerprint).and_return("TEST")
            @cli = CI.new(@ws)

            make_build_report
        end

        describe "pull" do
            it "pulls already built packages from the cache" do
                make_archive("a", "TEST")

                results = @cli.cache_pull(@archive_dir)
                assert_equal({ "a" => {'cached' => true, 'fingerprint' => 'TEST'} },
                    results)

                contents = File.read(File.join(@pkg.autobuild.prefix, 'contents'))
                assert_equal 'archive', contents.strip
            end
            it "ignores packages that are not already in the cache" do
                cli = CI.new(@ws)
                results = cli.cache_pull(@archive_dir)
                assert_equal({ "a" => {'cached' => false, 'fingerprint' => 'TEST'} },
                    results)

                refute File.directory?(@pkg.autobuild.prefix)
            end
        end

        describe "push" do
            it "pushes packages that are not already in the cache" do
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                results = @cli.cache_push(@archive_dir)
                assert_equal({ "a" => {'updated' => true, 'fingerprint' => 'TEST'} },
                    results)

                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert_equal "prefix", File.read(
                    File.join(@archive_dir, @pkg.name, "contents"))
            end
            it "ignores packages which were not in the last build" do
                File.open(@ws.build_report_path, 'w') do |io|
                    JSON.dump({'build_report' => { 'packages' => [] }}, io)
                end

                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                results = @cli.cache_push(@archive_dir)
                assert results.empty?, results
            end
            it "ignores packages which were not built in the last build" do
                make_build_report 'built' => false

                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                results = @cli.cache_push(@archive_dir)
                assert results.empty?, results
            end
            it "ignores packages that are already in the cache" do
                make_archive("a", "TEST")
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                results = @cli.cache_push(@archive_dir)
                assert_equal({ "a" => {'updated' => false, 'fingerprint' => 'TEST'} },
                    results)

                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert_equal "archive", File.read(
                    File.join(@archive_dir, @pkg.name, "contents"))
            end
            it "deals with race conditions on push" do
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))

                flexmock(@cli).should_receive(:system).explicitly.
                    with("tar", "czf", any, any, any).
                    pass_thru do
                        make_archive("a", "TEST")
                        true
                    end

                results = @cli.cache_push(@archive_dir)
                assert_equal({ "a" => {'updated' => true, 'fingerprint' => 'TEST'} },
                    results)

                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert %w[archive prefix].include?(File.read(
                    File.join(@archive_dir, @pkg.name, "contents")))
            end
        end

        def make_git(dir, file_content: File.basename(dir))
            FileUtils.mkdir_p dir
            system("git", "init", chdir: dir)
            File.open(File.join(dir, 'contents'), 'w') do |io|
                io.write file_content
            end
            system("git", "add", ".", chdir: dir)
        end

        def make_prefix(dir, file_content: 'prefix')
            FileUtils.mkdir_p dir
            File.open File.join(dir, 'contents'), 'w' do |io|
                io.write file_content
            end
        end

        def make_archive(package_name, fingerprint, file_content: 'archive')
            path = File.join(@archive_dir, package_name, fingerprint)
            FileUtils.mkdir_p File.dirname(path)

            tar_io = StringIO.new
            tar = Gem::Package::TarWriter.new(tar_io)
            tar.add_file 'contents', 0o644 do |file_io|
                file_io.write file_content
            end

            gziped_archive = IO.popen(["gzip", "-"], "r+") do |gzip_io|
                gzip_io.write tar_io.string
                gzip_io.close_write
                gzip_io.read
            end

            File.open(path, 'w') do |archive_io|
                archive_io.write gziped_archive
            end
        end

        def make_build_report(status = Hash.new)
            FileUtils.mkdir_p File.dirname(@ws.build_report_path)
            File.open(@ws.build_report_path, 'w') do |io|
                JSON.dump({
                    'build_report' => {
                        "packages": [
                            {"name": "a", "built": true}.merge(status)
                        ]
                    }
                }, io)
            end
        end
    end
end