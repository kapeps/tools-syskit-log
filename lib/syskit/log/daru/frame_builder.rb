# frozen_string_literal: true

module Syskit
    module Log
        module Daru
            # Utility class that allows to create a Daru dataframe based on
            # fields from a pocolog stream
            class FrameBuilder
                attr_reader :time_field
                attr_reader :vector_fields

                def initialize(type)
                    @type = type
                    @time_field = nil
                    @vector_fields = []

                    guess_time_field if @type <= Typelib::CompoundType
                end

                # Return the field that should be used as a time
                # index for samples of the given type
                #
                # @return [(String,Typelib::Type),nil] the field name and type,
                #    or nil if none has been found
                def self.find_time_field(type)
                    type.each_field
                        .find { |_, field_type| field_type.name == "/base/Time" }
                end

                # @api private
                #
                # Guess the field that should be used for the frame's index
                #
                # It pickes the first /base/Time field
                def guess_time_field
                    field_name, = self.class.find_time_field(@type)
                    return unless field_name

                    time { |b| b.__send__(field_name).microseconds }
                end

                # Returns true if a time field has either been guessed, or selected
                def time_field_selected?
                    @time_field
                end

                # Select the field that should be used as an index in the frame
                #
                # The selected field must be an integer representing a time whose
                # scale is compatible with the time given as center time to
                # {#to_daru_frame}
                #
                # If a "/base/Time" field can be found, it is automatically used
                def time(&block)
                    @time_field = resolve_field(&block)
                end

                # Remove the automatically guessed time field
                def no_time
                    @time_field = nil
                end

                # Do not use time as index
                def no_index
                    @no_index = true
                end

                # Extract a field as a column in the resulting frame
                #
                # @param [String,nil] the column name. If it is not given, the column
                #    name is generated from the extracted fields (see below).
                # @yieldparam [PathBuilder] an object that allows to extract specific
                #    fields and/or apply transformations before the value gets
                #    stored in the frame
                def add(name = nil, &block)
                    raise ArgumentError, "a block is required" unless block_given?

                    resolved = resolve_field(&block)
                    resolved.name = name if name
                    @vector_fields << resolved
                end

                # @api private
                ResolvedField = Struct.new :name, :path, :type, :transform, :vector_transform do
                    def resolve(value)
                        v = path.resolve(value).first.to_ruby
                        transform ? transform.call(v) : v
                    end

                    def create_vector(max_size)
                        if type <= Typelib::NumericType && !type.integer?
                            GSL::Vector.alloc(max_size)
                        else
                            Array.new(max_size)
                        end
                    end

                    def resize_vector(vector, actual_size)
                        if type <= Typelib::NumericType && !type.integer?
                            vector.subvector(actual_size).dup
                        else
                            vector[0, actual_size].dup
                        end
                    end

                    def apply_vector_transform(vector)
                        vector_transform ? vector_transform.call(vector) : vector
                    end
                end

                class InvalidDataType < ArgumentError; end

                # @api private
                #
                # Helper that resolves a field from the block given to {#add} and {#time}
                #
                # @return [ResolvedField]
                def resolve_field
                    builder = yield(PathBuilder.new(@type))
                    unless builder.__terminal?
                        raise InvalidDataType,
                              "field resolved to type #{builder.__type}, "\
                              "which is not simple nor transformed"
                    end
                    ResolvedField.new(builder.__name, builder.__path,
                                      builder.__type,
                                      builder.__transform, builder.__vector_transform)
                end

                # Convert the registered fields into a Daru frame
                #
                # @param [Time] center_time the time that should be used as
                #   zero in the frame index
                # @param [#raw_each] samples the object that will enumerate samples
                #   It must yield [realtime, logical_time, sample] the way
                #   Pocolog::SampleEnumerator does
                def to_daru_frame(center_time, samples)
                    if @time_field
                        to_daru_frame_with_time(center_time, samples)
                    else
                        to_daru_frame_without_time(center_time, samples)
                    end
                end

                # @api private
                #
                # Implementation of {#to_daru_frame} if a time field has been selected
                def to_daru_frame_with_time(center_time, samples)
                    data = @vector_fields.map do |field|
                        [field, field.create_vector(samples.max_size)]
                    end
                    data = [[@time_field, []]] + data

                    i = 0
                    samples.raw_each do |_, _, sample|
                        data.each do |field, path_data|
                            path_data[i] = field.resolve(sample)
                        end
                        i += 1
                    end

                    time = data.shift[1]
                    shift_time_microseconds(time, center_time)

                    data = data.map do |field, vector|
                        v = field.resize_vector(vector, i)
                        [field, field.apply_vector_transform(v)]
                    end

                    create_daru_frame(time, data)
                end

                # @api private
                #
                # Apply the center time to an array of times expressed in microseconds
                def shift_time_microseconds(time, center_time)
                    start_time_us = center_time.tv_sec * 1_000_000 + center_time.tv_usec
                    time.map! { |v| (v - start_time_us) / 1_000_000.0 }
                end

                # @api private
                #
                # Implementation of {#to_daru_frame} when there is no time
                # field, in which case the sample's logical time is used
                def to_daru_frame_without_time(center_time, samples)
                    time = []
                    data = @vector_fields.map { |p| [p, []] }
                    samples.raw_each do |_, lg, sample|
                        time << lg - center_time
                        data.each do |field, path_data|
                            path_data << field.resolve(sample)
                        end
                    end

                    create_daru_frame(time, data)
                end

                # @api private
                #
                # Create the Daru frame from the index and vectors
                #
                # @return [Daru::DataFrame]
                def create_daru_frame(time, vectors)
                    vectors = vectors.each_with_object({}) do |(field, path_data), h|
                        h[field.name] = path_data
                    end

                    if @no_index
                        vectors["time"] = time
                        ::Daru::DataFrame.new(vectors)
                    else
                        ::Daru::DataFrame.new(vectors, index: time)
                    end
                end
            end
        end
    end
end
