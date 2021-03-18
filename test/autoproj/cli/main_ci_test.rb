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
