module Syskit::Pocolog
    # A set of log streams
    class Streams
        # Load the set of streams available from a directory
        #
        # Note that in each directory, a stream's identity (task name,
        # port/property name and type) must be unique. If you need to mix
        # log streams, load files in separate {Streams} objects
        def self.from_dir(path)
            streams = new
            streams.add_dir(Pathname(path))
            streams
        end

        # Load the set of streams available from a file
        def self.from_file(file)
            streams = new
            streams.add_file(Pathname(file))
            streams
        end

        # The list of streams that are available
        attr_reader :streams

        # The common registry
        attr_reader :registry

        def initialize(streams = Array.new, registry: Typelib::Registry.new)
            @streams = streams
            @registry = registry
        end

        # The number of data streams in self
        def num_streams
            streams.size
        end

        # Enumerate the streams by grouping them per-task
        #
        # It will only enumerate the tasks that are "functional", that is that
        # they have a name and model, and the model can be resolved
        #
        # @param [Boolean] load_models whether the method should attempt to
        #   load the task's models if they are not yet loaded
        # @param [Boolean] skip_tasks_without_models whether the tasks whose
        #   model cannot be found should be enumerated or not
        # @param [Boolean] raise_on_missing_task_models whether the method
        #   should raise if a task model cannot be resolved
        # @param [#project_model_from_orogen_name] loader the object that should
        #   be used to load the missing models when load_models is true
        # @yieldparam [TaskStreams] task
        def each_task(load_models: true, skip_tasks_without_models: true, raise_on_missing_task_models: false, loader: Roby.app.default_loader)
            if !block_given?
                return enum_for(__method__, load_models: load_models,
                                skip_tasks_without_models: skip_tasks_without_models,
                                raise_on_missing_task_models: raise_on_missing_task_models,
                                loader: loader) 
            end

            available_tasks = Hash.new { |h, k| h[k] = Array.new }
            ignored_streams = Hash.new { |h, k| h[k] = Array.new }
            empty_task_models = Array.new
            each_stream do |s|
                if !(task_model_name = s.metadata['rock_task_model'])
                    next
                elsif task_model_name.empty?
                    empty_task_models << s
                    next
                end

                task_m = Syskit::TaskContext.find_model_from_orogen_name(task_model_name)
                if !task_m && load_models
                    orogen_project_name, *_tail = task_model_name.split('::')
                    begin
                        loader.project_model_from_name(orogen_project_name)
                    rescue OroGen::ProjectNotFound
                        raise if raise_on_missing_task_models
                    end
                    task_m = Syskit::TaskContext.find_model_from_orogen_name(task_model_name)
                end
                if task_m || !skip_tasks_without_models
                    available_tasks[s.metadata['rock_task_name']] << s
                elsif raise_on_missing_task_models
                    raise OroGen::NotFound, "cannot find #{task_model_name}"
                else
                    ignored_streams[task_model_name] << s
                end
            end

            if !empty_task_models.empty?
                Syskit::Pocolog.warn "ignored #{empty_task_models.size} streams that declared a task model, but left it empty: #{empty_task_models.map(&:name).sort.join(", ")}"
            end

            ignored_streams.each do |task_model_name, streams|
                Syskit::Pocolog.warn "ignored #{streams.size} streams because the task model #{task_model_name.inspect} cannot be found: #{streams.map(&:name).sort.join(", ")}"
            end

            available_tasks.each_value.map do |streams|
                yield(TaskStreams.new(streams))
            end
        end
        
        # Enumerate the streams
        #
        # @yieldparam [Pocolog::DataStream]
        def each_stream(&block)
            streams.each(&block)
        end

        # @api private
        #
        # Find the pocolog logfile groups and returns them
        #
        # @param [Pathname] path the directory to look into
        # @return [Array<Array<Pathname>>]
        def make_file_groups_in_dir(path)
            files_per_basename = Hash.new { |h, k| h[k] = Array.new }
            path.children.each do |file_or_dir|
                next if !file_or_dir.file?
                next if !(file_or_dir.extname == '.log')

                base_filename = file_or_dir.sub_ext('')
                id = base_filename.extname[1..-1]
                next if id !~ /^\d+$/
                base_filename = base_filename.sub_ext('')
                files_per_basename[base_filename.to_s][Integer(id)] = file_or_dir
            end
            files_per_basename.values.map do |list|
                list.compact
            end
        end

        # Load all log files from a directory
        def add_dir(path)
            make_file_groups_in_dir(path).each do |files|
                add_file_group(files)
            end
        end

        # Load all streams contained in a dataset
        #
        # @param [Datastore::Dataset] dataset
        # @return [void]
        def add_dataset(dataset)
            dataset.each_pocolog_lazy_stream do |stream|
                add_stream(stream)
            end
        end

        # @api private
        #
        # Update the metadata information stored within a given path
        def self.update_normalized_metadata(path)
            metadata_path = path + Streams::METADATA_BASENAME
            if metadata_path.exist?
                metadata = YAML.load(metadata_path.read)
            else
                metadata = Array.new
            end
            yield(metadata)
            metadata_path.open('w') do |io|
                YAML.dump(metadata, io)
            end
        end

        # @api private
        #
        # Save a stream's registry in a normalized dataset, and returns the
        # registry's checksum
        #
        # @param [Pathname] stream_path the path to the stream's backing file
        # @param [Pocolog::DataStream] stream the stream
        # @return [String] the registry's checksum
        def self.save_registry_in_normalized_dataset(stream_path, stream)
            dir, basename = stream_path.split
            stream_tlb = dir + "#{basename.basename('.log')}.tlb"
            if stream_tlb == stream_path
                raise ArgumentError, "cannot save the stream registry in #{stream_tlb}, it would overwrite the stream itself"
            end
            registry_xml = stream.type.to_xml
            stream_tlb.open('w') do |io|
                io.write registry_xml
            end
            Digest::SHA256.base64digest(registry_xml)
        end

        # @api private
        #
        # Create an entry suitable for marshalling in the metadata file for a
        # given stream
        #
        # @param [Pathname] stream_path the path to the stream's backing file
        # @param [Pocolog::DataStream] stream the stream
        # @return [Hash]
        def self.create_metadata_entry(stream_path, stream, registry_checksum)
            entry = Hash.new
            entry['path'] = stream_path.realpath.to_s
            entry['file_size'] = stream_path.stat.size
            entry['file_mtime'] = stream_path.stat.mtime
            entry['registry_sha256'] = registry_checksum

            entry['name'] = stream.name
            entry['type'] = stream.type.name
            entry['interval_rt'] = stream.interval_rt
            entry['interval_lg'] = stream.interval_lg
            entry['stream_size'] = stream.size
            entry['metadata'] = stream.metadata
            entry
        end

        # Returns the normalized basename for the given stream
        #
        # @param [Pocolog::DataStream] stream
        # @return [String]
        def self.normalized_filename(stream)
            task_name   = stream.metadata['rock_task_name'].gsub(/^\//, '')
            object_name = stream.metadata['rock_task_object_name']
            (task_name + "::" + object_name).gsub('/', ':')
        end

        # Open a list of pocolog files that belong as a group
        #
        # I.e. each file is part of the same general datastream
        #
        # @raise Errno::ENOENT if the path does not exist
        def add_file_group(group)
            file = Pocolog::Logfiles.new(*group.map { |path| path.open }, registry)
            file.streams.each do |s|
                add_stream(s)
            end
        end

        def sanitize_metadata(stream)
            if (model = stream.metadata['rock_task_model']) && model.empty?
                Syskit::Pocolog.warn "removing empty metadata property 'rock_task_model' from #{stream.name}"
                stream.metadata.delete('rock_task_model')
            end
            if task_name = stream.metadata['rock_task_name']
                stream.metadata['rock_task_name'] = task_name.gsub(/.*\//, '')
            end
        end

        # Load the streams from a log file
        def add_file(file)
            add_file_group([file])
        end

        # Add a new stream
        #
        # @param [Pocolog::DataStream] s
        def add_stream(s)
            sanitize_metadata(s)
            streams << s
        end

        # Find all streams whose metadata match the given query
        def find_all_streams(query)
            streams.find_all { |s| query === s }
        end

        # Find all streams that belong to a task
        def find_task_by_name(name)
            streams = find_all_streams(RockStreamMatcher.new.task_name(name))
            if !streams.empty?
                TaskStreams.new(streams)
            end
        end

        # Give access to the streams per-task by calling <task_name>_task
        def method_missing(m, *args, &block)
            MetaRuby::DSLs.find_through_method_missing(
                self, m, args, 'task' => "find_task_by_name") || super
        end

        # Creates a deployment group object that deploys all streams
        #
        # @param (see Streams#each_task)
        def to_deployment_group(load_models: true, skip_tasks_without_models: true, raise_on_missing_task_models: false, loader: Roby.app.default_loader)
            group = Syskit::Models::DeploymentGroup.new
            each_task(load_models: load_models,
                      skip_tasks_without_models: skip_tasks_without_models,
                      raise_on_missing_task_models: raise_on_missing_task_models,
                      loader: loader) do |task_streams|
                group.use_pocolog_task(task_streams)
            end
            group
        end
    end
end

