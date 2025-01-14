defmodule Nerves.Firmware.SSH.Application do
  @moduledoc false

  use Application

  @default_system_dir "/etc/ssh"

  @otp System.otp_release() |> Integer.parse() |> elem(0)

  # Check the keys passed in via application env.
  compile_time_keys = Application.get_env(:nerves_firmware_ssh, :authorized_keys, [])

  for key <- compile_time_keys do
    try do
      if @otp >= 24 do
        :ssh_file.decode(key, :auth_keys)
      else
        :public_key.ssh_decode(key, :auth_keys)
      end
    catch
      _, _ ->
        Mix.raise("""
        authorized_key provided in config.exs application env is not a valid SSH key!
        """)
    end
  end

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Task, [fn -> init() end], restart: :transient)
    ]

    opts = [strategy: :one_for_one, name: Nerves.Firmware.SSH.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def init() do
    port = Application.get_env(:nerves_firmware_ssh, :port, 8989)

    authorized_keys =
      Application.get_env(:nerves_firmware_ssh, :authorized_keys, [])
      |> Enum.join("\n")

    decoded_authorized_keys = decode_key(authorized_keys)

    cb_opts = [authorized_keys: decoded_authorized_keys]

    {:ok, _ref} =
      :ssh.daemon(port, [
        {:max_sessions, 1},
        {:id_string, :random},
        {:key_cb, {Nerves.Firmware.SSH.Keys, cb_opts}},
        {:system_dir, system_dir()},
        {:shell, &Nerves.Firmware.SSH.NoShell.start_shell/2},
        {:exec, &Nerves.Firmware.SSH.NoShell.start_exec/3},
        {:subsystems, [{'nerves_firmware_ssh', {Nerves.Firmware.SSH.Handler, []}}]}
      ])
  end

  def system_dir() do
    cond do
      system_dir = Application.get_env(:nerves_firmware_ssh, :system_dir) ->
        to_charlist(system_dir)

      File.dir?(@default_system_dir) and host_keys_readable?(@default_system_dir) ->
        to_charlist(@default_system_dir)

      true ->
        :code.priv_dir(:nerves_firmware_ssh)
    end
  end

  defp host_keys_readable?(path) do
    ["ssh_host_rsa_key", "ssh_host_dsa_key", "ssh_host_ecdsa_key"]
    |> Enum.map(fn name -> Path.join(path, name) end)
    |> Enum.any?(&readable?/1)
  end

  defp readable?(path) do
    case File.read(path) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # :public_key.ssh_decode/2 was deprecated in OTP 24 and will be removed in OTP 26.
  # :ssh_file.decode/2 was introduced in OTP 24
  if @otp >= 24 do
    defp decode_key(key), do: :ssh_file.decode(key, :auth_keys)
  else
    defp decode_key(key), do: :public_key.ssh_decode(key, :auth_keys)
  end
end
