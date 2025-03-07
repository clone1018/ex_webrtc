defmodule ExWebRTC.RTPSender do
  @moduledoc """
  Implementation of the [RTCRtpSender](https://www.w3.org/TR/webrtc/#rtcrtpsender-interface).
  """
  import Bitwise

  alias ExWebRTC.{MediaStreamTrack, RTPCodecParameters, Utils}
  alias ExSDP.Attribute.Extmap

  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"

  @type id() :: integer()

  @type t() :: %__MODULE__{
          id: id(),
          track: MediaStreamTrack.t() | nil,
          codec: RTPCodecParameters.t() | nil,
          rtp_hdr_exts: %{Extmap.extension_id() => Extmap.t()},
          mid: String.t() | nil,
          pt: non_neg_integer() | nil,
          ssrc: non_neg_integer() | nil,
          last_seq_num: non_neg_integer(),
          packets_sent: non_neg_integer(),
          bytes_sent: non_neg_integer(),
          markers_sent: non_neg_integer()
        }

  @enforce_keys [:id, :last_seq_num]
  defstruct @enforce_keys ++
              [
                :track,
                :codec,
                :mid,
                :pt,
                :ssrc,
                rtp_hdr_exts: %{},
                packets_sent: 0,
                bytes_sent: 0,
                markers_sent: 0
              ]

  @doc false
  @spec new(
          MediaStreamTrack.t() | nil,
          RTPCodecParameters.t() | nil,
          [Extmap.t()],
          String.t() | nil,
          non_neg_integer | nil
        ) :: t()
  def new(track, codec, rtp_hdr_exts, mid \\ nil, ssrc) do
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)
    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil

    %__MODULE__{
      id: Utils.generate_id(),
      track: track,
      codec: codec,
      rtp_hdr_exts: rtp_hdr_exts,
      pt: pt,
      ssrc: ssrc,
      last_seq_num: random_seq_num(),
      mid: mid
    }
  end

  @doc false
  @spec update(t(), String.t(), RTPCodecParameters.t(), [Extmap.t()]) :: t()
  def update(sender, mid, codec, rtp_hdr_exts) do
    if sender.mid != nil and mid != sender.mid, do: raise(ArgumentError)
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)
    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil

    %__MODULE__{sender | mid: mid, codec: codec, rtp_hdr_exts: rtp_hdr_exts, pt: pt}
  end

  # Prepares packet for sending i.e.:
  # * assigns SSRC, pt, seq_num, mid
  # * serializes to binary
  @doc false
  @spec send(t(), ExRTP.Packet.t()) :: {binary(), t()}
  def send(sender, packet) do
    %Extmap{} = mid_extmap = Map.fetch!(sender.rtp_hdr_exts, @mid_uri)

    mid_ext =
      %ExRTP.Packet.Extension.SourceDescription{text: sender.mid}
      |> ExRTP.Packet.Extension.SourceDescription.to_raw(mid_extmap.id)

    next_seq_num = sender.last_seq_num + 1 &&& 0xFFFF
    packet = %{packet | payload_type: sender.pt, ssrc: sender.ssrc, sequence_number: next_seq_num}

    data =
      packet
      |> ExRTP.Packet.add_extension(mid_ext)
      |> ExRTP.Packet.encode()

    sender = %{
      sender
      | last_seq_num: next_seq_num,
        packets_sent: sender.packets_sent + 1,
        bytes_sent: sender.bytes_sent + byte_size(data),
        markers_sent: sender.markers_sent + Utils.to_int(packet.marker)
    }

    {data, sender}
  end

  @doc false
  @spec get_stats(t(), non_neg_integer()) :: map()
  def get_stats(sender, timestamp) do
    %{
      timestamp: timestamp,
      type: :outbound_rtp,
      id: sender.id,
      ssrc: sender.ssrc,
      packets_sent: sender.packets_sent,
      bytes_sent: sender.bytes_sent,
      markers_sent: sender.markers_sent
    }
  end

  defp random_seq_num(), do: Enum.random(0..65_535)
end
