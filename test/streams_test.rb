require 'test_helper'

module Syskit::Pocolog
    describe Streams do
        subject { Streams.new }

        describe "#add_file" do
            it "adds the file's streams to the object" do
                create_logfile 'test.0.log' do
                    create_logfile_stream '/task.file'
                end
                subject.add_file(logfile_pathname('test.0.log'))
                assert_equal ['/task.file'], subject.each_stream.map(&:name)
            end

            it "raises ENOENT if the file does not exist" do
                assert_raises(Errno::ENOENT) { subject.add_file(Pathname('does_not_exist')) }
            end
        end

        describe ".from_dir" do
            it "creates a new streams object and adds the dir converted to pathname" do
                flexmock(Streams).new_instances.should_receive(:add_dir).once.with(Pathname.new('test'))
                assert_kind_of Streams, Streams.from_dir('test')
            end
        end

        describe ".from_file" do
            it "creates a new streams object and adds the file converted to pathname" do
                flexmock(Streams).new_instances.should_receive(:add_file).once.with(Pathname.new('test.0.log'))
                assert_kind_of Streams, Streams.from_file('test.0.log')
            end
        end

        describe "#add_file_group" do
            it "adds the group's streams to self" do
                create_logfile 'test0.0.log' do
                    create_logfile_stream '/stream0'
                    create_logfile_stream '/stream1'
                end
                create_logfile 'test1.0.log' do
                    create_logfile_stream '/stream0'
                    create_logfile_stream '/stream1'
                    create_logfile_stream '/stream2'
                end
                flexmock(subject).should_receive(:add_stream).
                    with(->(s) { s.name == '/stream0' }).once
                flexmock(subject).should_receive(:add_stream).
                    with(->(s) { s.name == '/stream1' }).once
                flexmock(subject).should_receive(:add_stream).
                    with(->(s) { s.name == '/stream2' }).once
                subject.add_file_group([logfile_pathname('test0.0.log'), logfile_pathname('test1.0.log')])
            end
        end

        describe "#add_stream" do
            describe "sanitize metadata" do
                it "removes an empty rock_task_model" do
                    create_logfile 'test.0.log' do
                        create_logfile_stream '/stream0',
                            metadata: Hash['rock_task_model' => '']
                    end
                    flexmock(Syskit::Pocolog).should_receive(:warn).
                        with("removing empty metadata property 'rock_task_model' from /stream0").
                        once
                    stream = open_logfile_stream('test.0.log', '/stream0')
                    subject.add_stream(stream)
                    refute stream.metadata['rock_task_model']
                end
                it "removes the nameservice prefix" do
                    create_logfile 'test0.0.log' do
                        create_logfile_stream '/stream0',
                            metadata: Hash['rock_task_name' => 'localhost/task']
                    end
                    stream = open_logfile_stream('test0.0.log', '/stream0')
                    subject.add_stream(stream)
                    assert_equal 'task', stream.metadata['rock_task_name']
                end
            end
        end

        describe "#add_dir" do
            it "raises ENOENT if the directory does not exist" do
                assert_raises(Errno::ENOENT) { subject.add_dir(Pathname.new("does_not_exist")) }
            end
            it "ignores the files that do not match the .NUM.log pattern" do
                FileUtils.touch((logfile_pathname + "a.file").to_s)
                flexmock(subject).should_receive(:add_file_group).never
                subject.add_dir(logfile_pathname)
            end
            it "adds files that match the .NUM.log pattern" do
                create_logfile('test0.0.log') {}
                create_logfile('test1.0.log') {}
                create_logfile('test2.0.log') {}
                flexmock(subject).should_receive(:add_file_group).
                    with([logfile_pathname + 'test0.0.log']).once
                flexmock(subject).should_receive(:add_file_group).
                    with([logfile_pathname + 'test1.0.log']).once
                flexmock(subject).should_receive(:add_file_group).
                    with([logfile_pathname + 'test2.0.log']).once
                subject.add_dir(logfile_pathname)
            end

            it "opens files that belong together, together" do
                create_logfile('test0.0.log') {}
                create_logfile('test0.1.log') {}
                create_logfile('test1.0.log') {}
                flexmock(subject).should_receive(:add_file_group).
                    with([logfile_pathname + 'test0.0.log', logfile_pathname + "test0.1.log"]).once
                flexmock(subject).should_receive(:add_file_group).
                    with([logfile_pathname + 'test1.0.log']).once
                subject.add_dir(logfile_pathname)
            end
        end

        describe "#make_file_groups_in_dir" do
            it "groups files that have the same basename together" do
                create_logfile('test0.0.log') {}
                create_logfile('test0.1.log') {}
                create_logfile('test0.2.log') {}
                create_logfile('test1.0.log') {}
                groups = subject.make_file_groups_in_dir(logfile_pathname)
                expected = [
                    [(logfile_pathname + 'test0.0.log'), (logfile_pathname + 'test0.1.log'), (logfile_pathname + 'test0.2.log')],
                    [logfile_pathname + 'test1.0.log']
                ]
                assert_equal expected, groups
            end
        end

        describe "#find_all_streams" do
            it "returns the streams that match the object" do
                create_logfile 'test.0.log' do
                    create_logfile_stream '/task.file'
                    create_logfile_stream '/other.task.file'
                    create_logfile_stream '/does.not.match'
                end
                subject.add_dir(logfile_pathname)

                streams = subject.streams

                query = flexmock
                query.should_receive(:===).
                    with(->(s) { streams.include?(s) }).
                    and_return { |s| s != streams[2] }
                assert_equal streams[0, 2], subject.find_all_streams(query)
            end
        end

        describe "#find_task_by_name" do
            before do
                create_logfile 'test.0.log' do
                    create_logfile_stream '/test0', metadata: Hash['rock_task_name' => "task"]
                    create_logfile_stream '/test1', metadata: Hash['rock_task_name' => "task"]
                    create_logfile_stream '/does.not.match', metadata: Hash['rock_task_name' => 'another_task']
                end
                subject.add_dir(logfile_pathname)
            end

            it "returns nil if there are no matching tasks" do
                assert !subject.find_task_by_name('does_not_exist')
            end

            it "returns a TaskStreams object with the matching streams" do
                streams = subject.find_task_by_name('task')
                assert_kind_of TaskStreams, streams
                assert_equal Set['/test0', '/test1'], streams.each_stream.map(&:name).to_set
            end

            describe "method_missing accessor" do
                it "returns the streams" do
                    streams = subject.task_task
                    assert_kind_of TaskStreams, streams
                    assert_equal Set['/test0', '/test1'], streams.each_stream.map(&:name).to_set
                end
                it "raises NoMethodError if no task exists" do
                    assert_raises(NoMethodError) do
                        subject.does_not_exist_task
                    end
                end
            end
        end

        describe "#each_task" do
            before do
                create_logfile 'test.0.log' do
                    create_logfile_stream '/test0', metadata: Hash['rock_task_model' => 'project::Task', 'rock_task_name' => "task"]
                    create_logfile_stream '/test1', metadata: Hash['rock_task_model' => 'project::Task', 'rock_task_name' => "task"]
                    create_logfile_stream '/other_project', metadata: Hash['rock_task_model' => 'other_project::Task', 'rock_task_name' => 'other_task']
                    create_logfile_stream '/not_task_model', metadata: Hash['rock_task_name' => 'task_without_model']
                end
                subject.add_dir(logfile_pathname)
            end

            # Helper method to test whether the method issues some warning
            # messages
            def should_warn(matcher)
                flexmock(Syskit::Pocolog).should_receive(:warn).with(matcher).once
            end

            it "ignores streams without a task model" do
                task_m = Syskit::TaskContext.new_submodel orogen_model_name: 'project::Task'
                other_task_m = Syskit::TaskContext.new_submodel orogen_model_name: 'other_project::Task'
                assert_equal ['task', 'other_task'], subject.each_task.map(&:task_name)
            end

            it "does not attempt to load the model's project if the task model is known" do
                Syskit::TaskContext.new_submodel orogen_model_name: 'project::Task'
                Syskit::TaskContext.new_submodel orogen_model_name: 'other_project::Task'
                flexmock(app).should_receive(:using_task_library).never
                subject.each_task.to_a
            end

            it "ignores streams that have a malformed rock_task_model name" do
                streams = Streams.new([s = subject.streams[0]])
                s.metadata['rock_task_model'] = ''
                should_warn /ignored 1 stream.*empty.*test0/
                flexmock(app).should_receive(:using_task_library).never
                assert_equal [], streams.each_task.to_a
            end

            it "does not attempt to load the model's project if load_models is false" do
                flexmock(app).should_receive(:using_task_library).never
                should_warn /ignored 2 streams.*project::Task.*\/test0, \/test1/
                should_warn /ignored.*other_project::Task.*other_project/
                assert_equal [], subject.each_task(load_models: false).to_a
            end

            it "attempts to load the model's project if load_models is true" do
                loader = flexmock
                loader.should_receive(:project_model_from_name).once.
                    with('project').
                    and_return { Syskit::TaskContext.new_submodel(orogen_model_name: 'project::Task') }
                loader.should_receive(:project_model_from_name).once.
                    with('other_project')
                should_warn /ignored 1 stream.*other_project::Task.*other_project/
                assert_equal ['task'], subject.each_task(load_models: true, loader: loader).map(&:task_name)
            end

            it "groups the streams per task name" do
                task_m = Syskit::TaskContext.new_submodel orogen_model_name: 'project::Task'
                other_task_m = Syskit::TaskContext.new_submodel orogen_model_name: 'other_project::Task'
                task, other_task = subject.each_task.to_a
                assert_equal ['/test0', '/test1'], task.streams.map(&:name)
                assert_equal ['/other_project'], other_task.streams.map(&:name)
            end
        end
    end
end
