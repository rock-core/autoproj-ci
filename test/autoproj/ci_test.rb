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
        end

        describe "pull" do
            before do
                make_build_report
            end

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
            it "optionally reports its progress" do
                make_archive("a", "TEST")

                flexmock(@cli).should_receive(:puts).explicitly.once.
                    with("pulled a (TEST)")
                @cli.should_receive(:puts).explicitly.once.
                    with("1 hits, 0 misses")
                @cli.cache_pull(@archive_dir, silent: false)
            end
        end

        describe "push" do
            before do
                make_build_report
            end

            it "pushes packages that are not already in the cache" do
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                results = @cli.cache_push(@archive_dir)
                assert_equal({ "a" => {'updated' => true, 'fingerprint' => 'TEST'} },
                    results)

                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert_equal "prefix", File.read(
                    File.join(@archive_dir, @pkg.name, "contents"))
            end
            it "does nothing if there is no build report" do
                FileUtils.rm_f @ws.build_report_path
                results = @cli.cache_push(@archive_dir)
                assert results.empty?
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

            it "optionally reports its progress" do
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))

                flexmock(@cli).should_receive(:puts).explicitly.once.
                    with("pushed a (TEST)")
                @cli.should_receive(:puts).explicitly.once.
                    with("1 updated packages, 0 reused entries")
                @cli.cache_push(@archive_dir, silent: false)
            end
        end

        describe "report" do
            it "uses the import report if the build report is not available" do
                make_cache_pull
                make_import_report('some' => 'flag')
                make_installation_manifest
                @cli.build_report(dir = make_tmpdir)
                report = JSON.load(File.read(File.join(dir, 'report.json')))
                assert_equal({'packages' => {'a' => {
                    'cached' => true, 'built' => true, 'some' => 'flag'
                }}}, report)
            end
            it "saves a consolidated manifest in report.json" do
                make_cache_pull
                make_build_report('some' => 'flag')
                make_installation_manifest
                @cli.build_report(dir = make_tmpdir)
                report = JSON.load(File.read(File.join(dir, 'report.json')))
                assert_equal({'a' => {
                    'cached' => true, 'built' => true, 'some' => 'flag'
                }}, report)
            end
            it "ignores an absent cache pull report" do
                make_build_report('some' => 'flag')
                make_installation_manifest
                @cli.build_report(dir = make_tmpdir)
                report = JSON.load(File.read(File.join(dir, 'report.json')))
                assert_equal({'a' => {
                    'built' => true, 'some' => 'flag'
                }}, report)
            end
            it "copies each package log directory contents to logs/" do
                make_installation_manifest

                logdir = make_tmpdir
                # the CLI loads the environment, which resets logdir
                # Force the return value
                flexmock(@pkg.autobuild, logdir: logdir)
                FileUtils.mkdir_p File.join(logdir, 'some', 'dir')
                FileUtils.touch File.join(logdir, 'some', 'dir', 'contents')
                @cli.build_report(dir = make_tmpdir)
                assert File.file?(File.join(dir, 'logs', 'some', 'dir', 'contents'))
            end
            it "does not copy the toplevel log/ directory" do
                make_installation_manifest

                logdir = make_tmpdir
                # the CLI loads the environment, which resets logdir
                # Force the return value
                flexmock(@pkg.autobuild, logdir: logdir)
                FileUtils.mkdir_p File.join(logdir, 'some', 'dir')
                FileUtils.touch File.join(logdir, 'some', 'dir', 'contents')
                dir = make_tmpdir
                FileUtils.mkdir_p File.join(dir, 'logs')
                @cli.build_report(dir)
                assert File.file?(File.join(dir, 'logs', 'some', 'dir', 'contents'))
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

        def make_import_report(status = Hash.new)
            make_report('import_report', status)
        end

        def make_build_report(status = Hash.new)
            make_report('build_report', status)
        end

        def make_report(type, status = Hash.new)
            path = @ws.send("#{type}_path")
            FileUtils.mkdir_p File.dirname(path)
            File.open(path, 'w') do |io|
                JSON.dump({
                    type => {
                        "packages": [
                            {"name": "a", "built": true}.merge(status)
                        ]
                    }
                }, io)
            end
        end

        def make_cache_pull(cached = true)
            File.open(File.join(@ws.root_dir, 'cache-pull.json'), 'w') do |io|
                JSON.dump({ 'a' => { 'cached' => cached } }, io)
            end
        end

        def make_installation_manifest
            manifest = Autoproj::InstallationManifest.new(
                @ws.installation_manifest_path)
            manifest.add_package(@pkg)
            manifest.save
        end
    end
end