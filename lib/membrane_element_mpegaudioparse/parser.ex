defmodule Membrane.Element.MPEGAudioParse.Parser do
  @moduledoc """
  Parses and splits into frames MPEG-1 Part 3 audio streams

  See `options/0` for available options
  """
  use Membrane.Element.Base.Filter
  use Membrane.Log, tags: :membrane_element_mpegaudioparse
  alias Membrane.Caps.Audio.MPEG
  import __MODULE__.Helper

  @mpeg_header_size 4

  def_input_pads input: [caps: :any, demand_unit: :bytes]

  def_output_pads output: [caps: MPEG]

  def_options skip_until_frame: [
                type: :boolean,
                description: """
                When set to true the parser will skip bytes until it finds a valid frame.
                Otherwise invalid frames will cause an error.
                """,
                default: false
              ]

  @impl true
  def handle_init(%__MODULE__{skip_until_frame: skip_flag}) do
    {:ok,
     %{
       queue: <<>>,
       caps: nil,
       skip_until_frame: skip_flag,
       frame_size: @mpeg_header_size
     }}
  end

  @impl true
  def handle_demand(:output, n_bufs, :buffers, _params, state) do
    %{queue: queue, frame_size: frame_size} = state
    demanded_bytes = frame_size * n_bufs - byte_size(queue) + @mpeg_header_size
    {{:ok, demand: {:input, demanded_bytes}}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{payload: payload}, _params, state) do
    %{queue: queue, caps: caps, frame_size: frame_size, skip_until_frame: skip_flag} = state

    data =
      if skip_flag do
        (queue <> payload) |> skip_to_frame()
      else
        queue <> payload
      end

    case do_parse(data, caps, frame_size, skip_flag, []) do
      {:ok, actions, new_queue, new_caps, new_frame_size} ->
        actions = [{:redemand, :output} | actions] |> Enum.reverse()
        {{:ok, actions}, %{state | queue: new_queue, caps: new_caps, frame_size: new_frame_size}}

      {:error, reason} ->
        raise """
        Error while parsing frame. You may consider using "skip_to_frame" option to prevent this error.
        Reason: #{inspect(reason, pretty: true)}
        """
    end
  end

  @impl true
  def handle_caps(:input, _caps, _options, state), do: {:ok, state}

  defp do_parse(<<>>, previous_caps, prev_frame_size, _, acc),
    do: {:ok, acc, <<>>, previous_caps, prev_frame_size}

  # We have at least header.
  defp do_parse(
         <<0b11111111111::size(11), _::bitstring>> = payload,
         previous_caps,
         prev_frame_size,
         skip_flag,
         acc
       )
       when byte_size(payload) >= @mpeg_header_size do
    <<0b11111111111::size(11), version::2-bitstring, layer::2-bitstring, crc_enabled::1-bitstring,
      bitrate::4-bitstring, sample_rate::2-bitstring, padding_enabled::1-bitstring,
      private::1-bitstring, channel_mode::2-bitstring, mode_extension::2-bitstring,
      copyright::1-bitstring, original::1-bitstring, emphasis_mode::2-bitstring,
      _rest::bitstring>> = payload

    version = parse_version(version)
    layer = parse_layer(layer)
    channel_mode = parse_channel_mode(channel_mode)
    channels = parse_channel_count(channel_mode)
    crc_enabled = parse_crc_enabled(crc_enabled)
    bitrate = parse_bitrate(bitrate, version, layer)
    sample_rate = parse_sample_rate(sample_rate, version)
    padding_enabled = parse_padding_enabled(padding_enabled)

    caps = %MPEG{
      version: version,
      layer: layer,
      crc_enabled: crc_enabled,
      bitrate: bitrate,
      sample_rate: sample_rate,
      padding_enabled: padding_enabled,
      private: parse_private(private),
      channel_mode: channel_mode,
      channels: channels,
      mode_extension: parse_mode_extension(mode_extension, channel_mode),
      copyright: parse_copyright(copyright),
      original: parse_original(original),
      emphasis_mode: parse_emphasis_mode(emphasis_mode)
    }

    with :ok <- validate_caps(caps),
         frame_size = MPEG.frame_size(caps),
         :full_frame <- verify_payload_size(payload, frame_size),
         <<frame_payload::size(frame_size)-binary, rest::bitstring>> <- payload,
         :ok <- validate_frame_start(rest) do
      new_acc =
        if previous_caps != caps do
          [{:caps, {:output, caps}} | acc]
        else
          acc
        end

      frame_buffer = {:buffer, {:output, %Membrane.Buffer{payload: frame_payload}}}
      do_parse(rest, caps, frame_size, skip_flag, [frame_buffer | new_acc])
    else
      {:error, :invalid_frame} ->
        if skip_flag do
          payload
          |> force_skip_to_frame()
          |> do_parse(previous_caps, prev_frame_size, skip_flag, acc)
        else
          {:error, {:invalid_frame, payload}}
        end

      {:partial_frame, frame_size} ->
        {:ok, acc, payload, previous_caps, frame_size}
    end
  end

  defp do_parse(payload, _, _, _, _)
       when byte_size(payload) >= @mpeg_header_size do
    {:error, {:invalid_frame, payload}}
  end

  defp do_parse(payload, previous_caps, prev_frame_size, _, acc) do
    {:ok, acc, payload, previous_caps, prev_frame_size}
  end

  defp validate_caps(%MPEG{} = caps) do
    # :free as in free format means bitrate is not specified. Currently it's not supported.
    if caps |> Map.values() |> Enum.any?(fn val -> val in [:invalid, :free] end) do
      {:error, :invalid_frame}
    else
      :ok
    end
  end

  defp verify_payload_size(payload, frame_size) do
    if byte_size(payload) >= frame_size do
      :full_frame
    else
      {:partial_frame, frame_size}
    end
  end

  # Check if argument can be a valid frame. If there's not enough bytes to perform check, assume it's ok
  defp validate_frame_start(<<0b11111111111::size(11), _::bitstring>>), do: :ok
  defp validate_frame_start(<<_::size(11), _::bitstring>>), do: {:error, :invalid_frame}
  defp validate_frame_start(_), do: :ok

  defp force_skip_to_frame(<<>>), do: <<>>

  defp force_skip_to_frame(payload) do
    payload |> binary_part(1, byte_size(payload) - 1) |> skip_to_frame
  end

  defp skip_to_frame(<<>>), do: <<>>
  defp skip_to_frame(<<0b11111111111::size(11), _::bitstring>> = frame), do: frame

  defp skip_to_frame(payload) do
    # Skip one byte to avoid infinite loop
    next_payload = payload |> binary_part(1, byte_size(payload) - 1)
    size = byte_size(next_payload)

    case next_payload |> :binary.match(<<0xFF>>) do
      {pos, _len} ->
        debug("Dropped bytes: #{inspect(binary_part(payload, 0, pos + 1))}")
        next_payload |> binary_part(pos, size - pos)

      :nomatch ->
        <<>>
    end
    |> skip_to_frame()
  end
end
