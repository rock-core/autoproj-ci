# frozen_string_literal: true

require "test_helper"
require "rubygems/package"
require "timecop"

module Autoproj::CLI # rubocop:disable Style/ClassAndModuleChildren
    describe CI do
        before do
            @ws = ws_create
            @archive_dir = make_tmpdir
            @prefix_dir = make_tmpdir

            @pkg = ws_define_package :cmake, "a"
            flexmock(@pkg.autobuild).should_receive(:fingerprint).and_return("TEST")
            @cli = CI.new(@ws)
            flexmock(@cli)
        end

        describe "pull" do
            before do
                make_build_report
            end

            it "pulls already built packages from the cache" do
                make_archive("a", "TEST")
                make_metadata("a", "TEST", timestamp: (time = Time.now))

                results = @cli.cache_pull(@archive_dir)
                assert_equal(
                    {
                        "a" => {
                            "cached" => true, "fingerprint" => "TEST",
                            "build" => {
                                "invoked" => true,
                                "timestamp" => time.to_s
                            }
                        }
                    }, results
                )

                contents = File.read(File.join(@pkg.autobuild.prefix, "contents"))
                assert_equal "archive", contents.strip
            end
            it "does not pull a package if its tests are enabled but "\
               "have never been invoked" do
                make_archive("a", "TEST")
                make_metadata("a", "TEST", test: {})
                flexmock(@pkg.autobuild.test_utility, enabled?: true)

                results = @cli.cache_pull(@archive_dir)
                assert_equal(
                    {
                        "a" => {
                            "cached" => false, "fingerprint" => "TEST"
                        }
                    }, results
                )
            end
            it "reports if it does not pull the package because of missing tests" do
                make_archive("a", "TEST")
                make_metadata("a", "TEST", timestamp: Time.now, test: {})
                flexmock(@pkg.autobuild.test_utility, enabled?: true)

                flexmock(@pkg.autobuild)
                    .should_receive(:message)
                    .once.with("%s: has tests that have never been invoked, "\
                               "not pulling from cache")
                flexmock(@pkg.autobuild)
                    .should_receive(:message)
                    .once.with("%s: TEST not in cache, or not pulled from cache")
                @cli.cache_pull(@archive_dir)
            end
            it "does not pull an already built package specified in ignore" do
                make_archive("a", "TEST")

                results = @cli.cache_pull(@archive_dir, ignore: ["a"])
                assert_equal({ "a" => { "cached" => false, "fingerprint" => "TEST" } },
                             results)

                refute File.directory?(@pkg.autobuild.prefix)
            end
            it "ignores packages that are not already in the cache" do
                cli = CI.new(@ws)
                results = cli.cache_pull(@archive_dir)
                assert_equal({ "a" => { "cached" => false, "fingerprint" => "TEST" } },
                             results)

                refute File.directory?(@pkg.autobuild.prefix)
            end
            it "reports its progress" do
                make_archive("a", "TEST")

                flexmock(@pkg.autobuild).should_receive(:message)
                                        .once.with("%s: pulled TEST", :green)
                flexmock(Autoproj).should_receive(:message)
                                  .once.with("1 hits, 0 misses")
                @cli.cache_pull(@archive_dir)
            end
        end

        describe "#cache_state" do
            it "determines if a cache entry can be used" do
                make_archive("a", "TEST")
                make_metadata("a", "TEST", timestamp: Time.now)

                results = @cli.cache_state(@archive_dir)
                assert_equal(
                    {
                        "a" => {
                            "path" => File.join(@archive_dir, "a", "TEST"),
                            "cached" => true, "metadata" => true, "fingerprint" => "TEST"
                        }
                    }, results
                )
            end

            it "determines if there are no cache entries" do
                cli = CI.new(@ws)
                results = cli.cache_state(@archive_dir)
                assert_equal(
                    {
                        "a" => {
                            "path" => File.join(@archive_dir, "a", "TEST"),
                            "cached" => false, "metadata" => false,
                            "fingerprint" => "TEST"
                        }
                    }, results
                )
            end
        end

        describe "push" do
            before do
                FileUtils.mkdir_p @ws.log_dir
            end

            it "pushes packages that are not already in the cache" do
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                make_build_report(add: { "some" => "flag" }, timestamp: (time = Time.now))
                results = @cli.cache_push(@archive_dir)
                assert_equal({ "a" => { "updated" => true, "fingerprint" => "TEST" } },
                             results)

                metadata = JSON.parse(
                    File.read(File.join(@archive_dir, @pkg.name, "TEST.json"))
                )
                assert_equal(
                    {
                        "build" => { "invoked" => true, "success" => true,
                                     "timestamp" => time.to_s, "some" => "flag" }
                    }, metadata
                )
                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert_equal "prefix", File.read(
                    File.join(@archive_dir, @pkg.name, "contents")
                )
            end
            it "does nothing if there is no build report" do
                results = @cli.cache_push(@archive_dir)
                assert results.empty?
            end
            it "does nothing if there is a report but it contains no build info" do
                make_import_report
                results = @cli.cache_push(@archive_dir)
                assert results.empty?
            end
            it "ignores packages which were not in the last build" do
                File.open(@ws.build_report_path, "w") do |io|
                    JSON.dump({ "build_report" => { "packages" => [] } }, io)
                end

                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                results = @cli.cache_push(@archive_dir)
                assert results.empty?, results
            end
            it "ignores packages which were not successfully built in the last build" do
                make_build_report add: { "success" => false }

                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                results = @cli.cache_push(@archive_dir)
                assert results.empty?, "packages were pushed that should "\
                                       "not have: #{results}"
            end
            it "updates packages whose cache entry was not used" do
                make_build_report
                make_archive("a", "TEST")
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                results = @cli.cache_push(@archive_dir)
                assert_equal({ "a" => { "updated" => true, "fingerprint" => "TEST" } },
                             results)

                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert_equal "prefix", File.read(
                    File.join(@archive_dir, @pkg.name, "contents")
                )
            end
            it "ignores packages which were not built during this run" do
                make_archive("a", "TEST")
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                make_cache_pull({ "build" => { "success" => true } })
                results = @cli.cache_push(@archive_dir)
                assert_equal({}, results)

                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert_equal "archive", File.read(
                    File.join(@archive_dir, @pkg.name, "contents")
                )
            end
            it "ignores packages which build was not successful" do
                make_archive("a", "TEST")
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                make_build_report add: { "success" => false }
                results = @cli.cache_push(@archive_dir)
                assert_equal({}, results)

                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert_equal "archive", File.read(
                    File.join(@archive_dir, @pkg.name, "contents")
                )
            end
            it "deals with race conditions on push" do
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                make_build_report

                flexmock(@cli).should_receive(:system).explicitly
                              .with("tar", "czf", any, any, any)
                              .pass_thru do
                                  make_archive("a", "TEST")
                                  true
                              end

                results = @cli.cache_push(@archive_dir)
                assert_equal({ "a" => { "updated" => true, "fingerprint" => "TEST" } },
                             results)

                system("tar", "xzf", "TEST", chdir: File.join(@archive_dir, @pkg.name))
                assert %w[archive prefix].include?(
                    File.read(File.join(@archive_dir, @pkg.name, "contents"))
                )
            end

            it "reports its progress" do
                make_prefix(File.join(@ws.prefix_dir, @pkg.name))
                make_build_report

                flexmock(@pkg.autobuild).should_receive(:message).once
                                        .with("%s: pushed TEST", :green)
                flexmock(Autoproj).should_receive(:message).once
                                  .with("1 updated packages, 0 reused entries")
                @cli.cache_push(@archive_dir)
            end
        end

        describe "report" do
            before do
                Timecop.freeze
            end
            after do
                Timecop.return
            end

            def self.consolidated_report_single_behavior( # rubocop:disable Metrics/AbcSize
                report_type,
                report_path_accessor:
            )
                it "reads the #{report_type} report" do
                    make_report("#{report_type}_report",
                                add: { "some" => "flag" },
                                path: report_path_accessor.call(@ws))
                    make_installation_manifest
                    @cli.create_report(dir = make_tmpdir)
                    report = JSON.parse(File.read(File.join(dir, "report.json")))
                    assert_equal(
                        {
                            "packages" => {
                                "a" => {
                                    report_type => {
                                        "cached" => false,
                                        "invoked" => true,
                                        "success" => true,
                                        "some" => "flag",
                                        "timestamp" => Time.now.to_s
                                    }
                                }
                            }
                        }, report
                    )
                end
                it "keeps cached #{report_type} info if there is no new info "\
                   "in the #{report_type} report" do
                    make_cache_pull({ report_type => { "invoked" => true } })
                    make_installation_manifest
                    @cli.create_report(dir = make_tmpdir)
                    report = JSON.parse(File.read(File.join(dir, "report.json")))
                    assert_equal(
                        {
                            "packages" => {
                                "a" => {
                                    report_type => {
                                        "cached" => true,
                                        "invoked" => true
                                    }
                                }
                            }
                        }, report
                    )
                end
                it "overwrites cache info with entries from the #{report_type} report" do
                    make_cache_pull(
                        { report_type => { "build" => { "invoked" => false } } }
                    )
                    make_report("#{report_type}_report",
                                add: { "some" => "flag" },
                                path: report_path_accessor.call(@ws))
                    make_installation_manifest
                    @cli.create_report(dir = make_tmpdir)
                    report = JSON.parse(File.read(File.join(dir, "report.json")))
                    assert_equal(
                        {
                            "packages" => {
                                "a" => {
                                    report_type => {
                                        "cached" => false,
                                        "invoked" => true,
                                        "success" => true,
                                        "some" => "flag",
                                        "timestamp" => Time.now.to_s
                                    }
                                }
                            }
                        }, report
                    )
                end
            end

            consolidated_report_single_behavior(
                "import", report_path_accessor: ->(ws) { ws.import_report_path }
            )
            consolidated_report_single_behavior(
                "build", report_path_accessor: ->(ws) { ws.build_report_path }
            )
            consolidated_report_single_behavior(
                "test", report_path_accessor: ->(ws) { ws.utility_report_path("test") }
            )

            it "saves a consolidated manifest in report.json" do
                make_cache_pull
                make_import_report(add: { "some" => "flag" }, timestamp: Time.now)
                make_build_report(add: { "some" => "other" }, timestamp: Time.now + 1)
                make_test_report(add: { "success" => false, "some" => "42" },
                                 timestamp: Time.now + 2)
                make_installation_manifest
                @cli.create_report(dir = make_tmpdir)
                report = JSON.parse(File.read(File.join(dir, "report.json")))
                assert_equal(
                    {
                        "packages" => {
                            "a" => {
                                "import" => { "cached" => false, "invoked" => true,
                                              "success" => true, "some" => "flag",
                                              "timestamp" => Time.now.to_s },
                                "build" => { "cached" => false, "invoked" => true,
                                             "success" => true, "some" => "other",
                                             "timestamp" => (Time.now + 1).to_s },
                                "test" => { "cached" => false, "invoked" => true,
                                            "success" => false, "some" => "42",
                                            "timestamp" => (Time.now + 2).to_s }
                            }
                        }
                    }, report
                )
            end
            it "ignores an absent cache pull report" do
                make_build_report(add: { "some" => "flag" })
                make_installation_manifest
                @cli.create_report(dir = make_tmpdir)
                report = JSON.parse(File.read(File.join(dir, "report.json")))
                assert_equal(
                    {
                        "packages" => {
                            "a" => {
                                "build" => { "invoked" => true, "success" => true,
                                             "cached" => false, "some" => "flag",
                                             "timestamp" => Time.now.to_s }
                            }
                        }
                    }, report
                )
            end
            it "ignores metadata from cache pull for non-pulled packages" do
                make_cache_pull({ "build" => { "invoked" => true } }, cached: false)
                make_installation_manifest
                @cli.create_report(dir = make_tmpdir)
                report = JSON.parse(File.read(File.join(dir, "report.json")))
                assert_equal({ "packages" => {} }, report)
            end
            it "copies each package log directory contents to logs/" do
                make_installation_manifest

                logdir = make_tmpdir
                # the CLI loads the environment, which resets logdir
                # Force the return value
                flexmock(@pkg.autobuild, logdir: logdir)
                FileUtils.mkdir_p File.join(logdir, "some", "dir")
                FileUtils.touch File.join(logdir, "some", "dir", "contents")
                @cli.create_report(dir = make_tmpdir)
                assert File.file?(File.join(dir, "logs", "some", "dir", "contents"))
            end
            it "does not copy the toplevel log/ directory" do
                make_installation_manifest

                logdir = make_tmpdir
                # the CLI loads the environment, which resets logdir
                # Force the return value
                flexmock(@pkg.autobuild, logdir: logdir)
                FileUtils.mkdir_p File.join(logdir, "some", "dir")
                FileUtils.touch File.join(logdir, "some", "dir", "contents")
                dir = make_tmpdir
                FileUtils.mkdir_p File.join(dir, "logs")
                @cli.create_report(dir)
                assert File.file?(File.join(dir, "logs", "some", "dir", "contents"))
            end
        end

        describe "#need_xunit_processing?" do
            it "returns false if the results directory does not exist" do
                output = File.join(@prefix_dir, "test")
                refute @cli.need_xunit_processing?(output, "some/file")
            end
            it "returns true if the folder has XML content" do
                FileUtils.touch(File.join(@prefix_dir, "test.xml"))
                assert @cli.need_xunit_processing?(@prefix_dir, "bla", force: true)
            end
            it "returns false if the xunit output already exists" do
                FileUtils.touch(File.join(@prefix_dir, "test.xml"))
                FileUtils.touch(output = File.join(@prefix_dir, "test.html"))
                refute @cli.need_xunit_processing?(@prefix_dir, output)
            end
            it "returns true if the xunit output already exists but force is true" do
                FileUtils.touch(File.join(@prefix_dir, "test.xml"))
                FileUtils.touch(output = File.join(@prefix_dir, "test.html"))
                assert @cli.need_xunit_processing?(@prefix_dir, output, force: true)
            end
        end

        describe "#postprocess_test_results" do
            describe "xunit processing" do
                it "skips packages that do not have tests" do
                    report = { "packages" => { "a" => {} } }
                    @cli.should_receive(:consolidated_report).and_return(report)
                    @cli.should_receive(:system).explicitly.never
                    @cli.process_test_results
                end
                it "skips packages for which need_xunit_processing? returns false" do
                    report = {
                        "packages" => { "a" => { "test" => { "target_dir" => "bla" } } }
                    }
                    @cli.should_receive(:consolidated_report).and_return(report)
                    @cli.should_receive(:need_xunit_processing?)
                        .with("bla", "bla.html", force: false).once
                        .and_return(false)
                    @cli.should_receive(:system).explicitly.never
                    @cli.process_test_results
                end
                it "processes packages for which need_xunit_processing? returns true" do
                    report = {
                        "packages" => { "a" => { "test" => { "target_dir" => "bla" } } }
                    }
                    @cli.should_receive(:consolidated_report).and_return(report)
                    @cli.should_receive(:need_xunit_processing?)
                        .with("bla", "bla.html", force: false).once
                        .and_return(true)
                    @cli.should_receive(:system).explicitly
                        .with("xunit-viewer", "--results=bla", "--output=bla.html")
                        .once.and_return(true)
                    @cli.process_test_results
                end
                it "warns if xunit-viewer failed" do
                    report = {
                        "packages" => { "a" => { "test" => { "target_dir" => "bla" } } }
                    }
                    @cli.should_receive(:consolidated_report).and_return(report)
                    @cli.should_receive(:need_xunit_processing?).and_return(true)
                    @cli.should_receive(:system).explicitly.and_return(false)
                    flexmock(Autoproj).should_receive(:warn)
                                      .with("xunit-viewer conversion failed for 'bla'")
                                      .once
                    @cli.process_test_results
                end
            end
        end

        describe "#cleanup_build_cache" do
            before do
                @cache_dir = make_tmpdir
                @paths = [create_file("a", 1024),
                          create_file("b", 1024),
                          create_file("c", 1024),
                          create_file("d", 1024)]
            end

            it "does nothing if the cache size is above the limit" do
                result = @cli.cleanup_build_cache @cache_dir, 5000
                @paths.each do |p|
                    assert File.exist?(p)
                    assert File.exist?("#{p}.json")
                end
                assert_equal 4096, result
            end

            it "removes the oldest entries to go below the cache limit" do
                sleep 1.5
                FileUtils.touch @paths[1]
                FileUtils.touch @paths[3]
                result = @cli.cleanup_build_cache @cache_dir, 3000
                [@paths[1], @paths[3]].each do |p|
                    assert File.exist?(p)
                    assert File.exist?("#{p}.json")
                end
                [@paths[0], @paths[2]].each do |p|
                    refute File.exist?(p)
                    refute File.exist?("#{p}.json")
                end
                assert_equal 2048, result
            end

            def create_file(path, size)
                path = File.join(@cache_dir, path)
                File.open(path, "w") do |io|
                    io.write " " * size
                end
                FileUtils.touch "#{path}.json"
                path
            end
        end

        def make_git(dir, file_content: File.basename(dir))
            FileUtils.mkdir_p dir
            system("git", "init", chdir: dir)
            File.open(File.join(dir, "contents"), "w") do |io|
                io.write file_content
            end
            system("git", "add", ".", chdir: dir)
        end

        def make_prefix(dir, file_content: "prefix")
            FileUtils.mkdir_p dir
            File.open File.join(dir, "contents"), "w" do |io|
                io.write file_content
            end
        end

        def make_archive(package_name, fingerprint, file_content: "archive")
            path = File.join(@archive_dir, package_name, fingerprint)
            FileUtils.mkdir_p File.dirname(path)

            tar_io = StringIO.new
            tar = Gem::Package::TarWriter.new(tar_io)
            tar.add_file "contents", 0o644 do |file_io|
                file_io.write file_content
            end

            gziped_archive = IO.popen(["gzip", "-"], "r+") do |gzip_io|
                gzip_io.write tar_io.string
                gzip_io.close_write
                gzip_io.read
            end

            File.open(path, "w") do |archive_io|
                archive_io.write gziped_archive
            end
        end

        def make_metadata(
            package_name, fingerprint,
            add: {}, test: nil, timestamp: Time.now
        )
            path = File.join(@archive_dir, package_name, "#{fingerprint}.json")
            FileUtils.mkdir_p File.dirname(path)

            metadata = {
                "build" => { "timestamp" => timestamp.to_s, "invoked" => true }
                       .merge(add)
            }
            metadata.merge!("test" => test) if test

            File.open(path, "w") do |io|
                JSON.dump(metadata, io)
            end
        end

        def make_import_report(add: {}, timestamp: Time.now)
            make_report("import_report", add: add, timestamp: timestamp)
        end

        def make_build_report(add: {}, timestamp: Time.now)
            make_report("build_report", add: add, timestamp: timestamp)
        end

        def make_test_report(add: {}, timestamp: Time.now)
            make_report("test_report", add: add, timestamp: timestamp,
                                       path: @ws.utility_report_path("test"))
        end

        def make_report(
            type, add: {}, timestamp: Time.now,
            path: @ws.send("#{type}_path")
        )
            FileUtils.mkdir_p File.dirname(path)
            File.open(path, "w") do |io|
                JSON.dump(
                    {
                        type => {
                            'timestamp': timestamp,
                            'packages': {
                                "a" => { 'invoked': true, 'success': true }.merge(add)
                            }
                        }
                    }, io
                )
            end
        end

        def make_cache_pull(new_info = {}, cached: true)
            File.open(File.join(@ws.root_dir, "cache-pull.json"), "w") do |io|
                JSON.dump(
                    {
                        "cache_pull_report" => {
                            "packages" => {
                                "a" => { "cached" => cached }.merge(new_info)
                            }
                        }
                    }, io
                )
            end
        end

        def make_installation_manifest
            manifest = Autoproj::InstallationManifest.new(
                @ws.installation_manifest_path
            )
            manifest.add_package(@pkg)
            manifest.save
        end
    end
end
