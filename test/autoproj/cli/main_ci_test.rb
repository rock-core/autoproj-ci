# frozen_string_literal: true

require 'test_helper'
require 'thor'
require 'autoproj/cli/main_ci'

module Autoproj::CLI # rubocop:disable Style/ClassAndModuleChildren, Style/Documentation
    describe MainCI do # rubocop:disable Metrics/BlockLength
        before do
            @ws = ws_create
            @archive_dir = make_tmpdir
            @prefix_dir = make_tmpdir
            @cli = CI.new(@ws)
        end

        describe '#test' do
            it 'filters out cached packages' do
                report = {
                    'packages' => {
                        'a' => {
                            'build' => { 'cached' => true, 'success' => true }
                        },
                        'b' => {
                            'build' => { 'cached' => false, 'success' => true }
                        }
                    }
                }
                flexmock(CI).new_instances.should_receive(:consolidated_report)
                            .and_return(report)
                flexmock(Process)
                    .should_receive(:exec).once
                    .with(any, /autoproj/, 'test', 'exec', '--interactive=f', 'b')

                Dir.chdir(@ws.root_dir) do
                    MainCI.start(['test'])
                end
            end
            it 'filters out packages that are not successfully built' do
                report = {
                    'packages' => {
                        'a' => {
                            'build' => { 'cached' => false, 'success' => false }
                        },
                        'b' => {
                            'build' => { 'cached' => false, 'success' => true }
                        }
                    }
                }
                flexmock(CI).new_instances.should_receive(:consolidated_report)
                            .and_return(report)
                flexmock(Process)
                    .should_receive(:exec).once
                    .with(any, /autoproj/, 'test', 'exec', '--interactive=f', 'b')

                Dir.chdir(@ws.root_dir) { MainCI.start(['test']) }
            end
            it 'does not call autoproj test if there are no packages' do
                flexmock(CI).new_instances.should_receive(:consolidated_report)
                            .and_return('packages' => {})
                flexmock(Process).should_receive(:exec).never
            end
            it 'does not call autoproj test if all packages have been filtered out' do
                report = {
                    'packages' => {
                        'a' => {
                            'build' => { 'cached' => false, 'success' => false }
                        },
                        'b' => {
                            'build' => { 'cached' => false, 'success' => false }
                        }
                    }
                }
                flexmock(CI).new_instances.should_receive(:consolidated_report)
                            .and_return(report)
                flexmock(Process).should_receive(:exec).never
            end
        end
    end
end
