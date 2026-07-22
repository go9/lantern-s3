defmodule LanternS3.Errors do
  @moduledoc """
  Maps storage / ExAws failure terms to short user-facing copy.

  Raw `inspect/1` output is never returned for UI; callers should log the
  original reason with `Logger` and show `humanize/1` (or `log_and_humanize/2`).
  """

  require Logger

  @doc """
  Returns a short human-readable sentence for a storage error reason.
  """
  @spec humanize(term()) :: String.t()
  def humanize({:http_error, 401, _}), do: "Not authorized."
  def humanize({:http_error, 403, _}), do: "Access denied."
  def humanize({:http_error, 404, _}), do: "Not found."
  def humanize({:http_error, 408, _}), do: "The request timed out. Try again."
  def humanize({:http_error, 429, _}), do: "Too many requests. Try again shortly."

  def humanize({:http_error, status, _}) when is_integer(status) and status >= 500 do
    "Storage is temporarily unavailable (HTTP #{status})."
  end

  def humanize({:http_error, status, _}) when is_integer(status) do
    "Storage request failed (HTTP #{status})."
  end

  def humanize({:http_error, _, _}), do: "Storage request failed."

  def humanize(:timeout), do: "The request timed out. Try again."
  def humanize({:timeout, _}), do: "The request timed out. Try again."
  def humanize(:checkout_timeout), do: "The request timed out. Try again."

  def humanize(:econnrefused), do: "Could not connect to storage."
  def humanize(:nxdomain), do: "Could not resolve the storage host."
  def humanize(:closed), do: "Connection to storage was closed."
  def humanize({:closed, _}), do: "Connection to storage was closed."
  def humanize(:enetunreach), do: "Could not reach storage."
  def humanize(:ehostunreach), do: "Could not reach storage."

  def humanize(:copy_ok_delete_failed),
    do: "Copied, but the original could not be deleted."

  def humanize(%{reason: reason}), do: humanize(reason)
  def humanize(%{message: msg}) when is_binary(msg) and msg != "", do: msg
  def humanize(msg) when is_binary(msg) and msg != "", do: msg

  def humanize(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
    |> Kernel.<>(".")
  end

  def humanize(_), do: "Something went wrong. Try again."

  @doc """
  Logs `reason` with `inspect/1` and returns `humanize/1` for the UI.
  """
  @spec log_and_humanize(String.t(), term()) :: String.t()
  def log_and_humanize(context, reason) when is_binary(context) do
    Logger.warning("LanternS3 #{context}: #{inspect(reason)}")
    humanize(reason)
  end
end
