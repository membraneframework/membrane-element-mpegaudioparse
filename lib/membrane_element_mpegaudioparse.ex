defmodule Membrane.Element.MPEGAudioParse do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = []

    opts = [strategy: :one_for_one, name: Membrane.Element.MPEGAudioParse]
    Supervisor.start_link(children, opts)
  end
end
