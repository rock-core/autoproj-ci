# frozen_string_literal: true

require "test_helper"
require "thor"
require "autoproj/cli/main_ci"

module Autoproj::CLI # rubocop:disable Style/ClassAndModuleChildren
    describe MainCI do
        before do
            @ws = ws_create
            @archive_dir = make_tmpdir
            @prefix_dir = make_tmpdir
            @cli = CI.new(@ws)
        end

        def make_cache_pull(packages = {})
            File.open(File.join(@ws.root_dir, "cache-pull.json"), "w") do |io|
                JSON.dump(
                    {
                        "cache_pull_report" => {
                            "packages" => packages
                        }
                    }, io
                )
            end
        end

        describe "#build" do
            it "uses an existing cache pull report" do
                report = {
                    "pulled" => { "cached" => true }
                }
                make_cache_pull(report)
                flexmock(Process)
                    .should_receive(:exec).once
                    .with(Gem.ruby, $PROGRAM_NAME, "build", "--interactive=f",
                          "--progress=f", "--color=f", "--not", "pulled")

                Dir.chdir(@ws.root_dir) do
                    MainCI.start(%w[build])
                end
            end

            it "pulls cache if --cache is passed even if a report exists" do
                report = {
                    "pulled" => { "cached" => true }
                }
                make_cache_pull
                flexmock(MainCI)
                    .new_instances
                    .should_receive(:cache_pull)
                    .with("/var/cache/autoproj", ignore: [])
                    .and_return(report)

                flexmock(Process)
                    .should_receive(:exec).once
                    .with(Gem.ruby, $PROGRAM_NAME, "build", "--interactive=f",
                          "--progress=f", "--color=f", "--not", "pulled")

                Dir.chdir(@ws.root_dir) do
                    MainCI.start(%w[build --cache /var/cache/autoproj])
                end
            end
        end

        describe "#osdeps" do
            it "runs osdeps with the packages that were not pulled" do
                make_cache_pull(
                    {
                        "pulled" => { "cached" => true },
                        "not_pulled" => { "cached" => false }
                    }
                )
                flexmock(Process)
                    .should_receive(:exec).once
                    .with(Gem.ruby, $PROGRAM_NAME, "osdeps",
                          "--interactive=f", "--progress=f", "--color=f", "not_pulled")
                Dir.chdir(@ws.root_dir) do
                    MainCI.start(%w[osdeps])
                end
            end

            it "does nothing if report doesn't exist" do
                flexmock(Process).should_receive(:exec).never
                Dir.chdir(@ws.root_dir) do
                    MainCI.start(%w[osdeps])
                end
            end

            it "does nothing if there's nothing to build" do
                make_cache_pull(
                    {
                        "pulled" => { "cached" => true }
                    }
                )
                flexmock(Process).should_receive(:exec).never
                Dir.chdir(@ws.root_dir) do
                    MainCI.start(%w[osdeps])
                end
            end
        end

        describe "#test" do
            it "filters out cached packages" do
                report = {
                    "packages" => {
                        "a" => {
                            "build" => { "cached" => true, "success" => true }
                        },
                        "b" => {
                            "build" => { "cached" => false, "success" => true }
                        }
                    }
                }
                flexmock(CI).new_instances.should_receive(:consolidated_report)
                            .and_return(report)
                flexmock(Process)
                    .should_receive(:exec).once
                    .with(Gem.ruby, "autoproj", "test", "exec", "--interactive=f", "b")

                Dir.chdir(@ws.root_dir) do
                    MainCI.start(["test", "--autoproj=autoproj"])
                end
            end
            it "filters out packages that are not successfully built" do
                report = {
                    "packages" => {
                        "a" => {
                            "build" => { "cached" => false, "success" => false }
                        },
                        "b" => {
                            "build" => { "cached" => false, "success" => true }
                        }
                    }
                }
                flexmock(CI).new_instances.should_receive(:consolidated_report)
                            .and_return(report)
                flexmock(Process)
                    .should_receive(:exec).once
                    .with(Gem.ruby, "autoproj", "test", "exec", "--interactive=f", "b")

                Dir.chdir(@ws.root_dir) { MainCI.start(["test", "--autoproj=autoproj"]) }
            end
            it "does not call autoproj test if there are no packages" do
                flexmock(CI).new_instances.should_receive(:consolidated_report)
                            .and_return("packages" => {})
                flexmock(Process).should_receive(:exec).never
                Dir.chdir(@ws.root_dir) { MainCI.start(["test"]) }
            end
            it "does not call autoproj test if all packages have been filtered out" do
                report = {
                    "packages" => {
                        "a" => {
                            "build" => { "cached" => false, "success" => false }
                        },
                        "b" => {
                            "build" => { "cached" => false, "success" => false }
                        }
                    }
                }
                flexmock(CI).new_instances.should_receive(:consolidated_report)
                            .and_return(report)
                flexmock(Process).should_receive(:exec).never
                Dir.chdir(@ws.root_dir) { MainCI.start(["test"]) }
            end
        end

        describe "result" do
            before do
                flexmock(MainCI)
                @report_dir = make_tmpdir
            end

            it "exits with 0 on success" do
                write_report(
                    {
                        "packages" => {
                            "a" => { "build" => {
                                "invoked" => true, "cached" => false, "success" => true
                            } },
                            "b" => { "build" => {
                                "invoked" => true, "cached" => false, "success" => true
                            } }
                        }
                    }
                )
                MainCI.new_instances.should_receive(:exit).explicitly.with(0).once
                      .and_throw(:exit)

                catch(:exit) do
                    Dir.chdir(@ws.root_dir) { MainCI.start(["result", @report_dir]) }
                end
            end

            it "exits with 1 on cached failure" do
                write_report(
                    {
                        "packages" => {
                            "a" => { "build" => {
                                "invoked" => true, "cached" => false, "success" => true
                            } },
                            "b" => { "build" => {
                                "invoked" => true, "cached" => true, "success" => false
                            } }
                        }
                    }
                )
                MainCI.new_instances.should_receive(:exit).explicitly.with(1).once
                      .and_throw(:exit)

                catch(:exit) do
                    Dir.chdir(@ws.root_dir) { MainCI.start(["result", @report_dir]) }
                end
            end

            it "exits with 1 on non-cached failure" do
                write_report(
                    {
                        "packages" => {
                            "a" => { "build" => {
                                "invoked" => true, "cached" => false, "success" => true
                            } },
                            "b" => { "build" => {
                                "invoked" => true, "cached" => false, "success" => false
                            } }
                        }
                    }
                )
                MainCI.new_instances.should_receive(:exit).explicitly.with(1).once
                      .and_throw(:exit)

                catch(:exit) do
                    Dir.chdir(@ws.root_dir) { MainCI.start(["result", @report_dir]) }
                end
            end

            def write_report(report)
                File.open(File.join(@report_dir, "report.json"), "w") do |io|
                    JSON.dump(report, io)
                end
            end
        end
    end
end
