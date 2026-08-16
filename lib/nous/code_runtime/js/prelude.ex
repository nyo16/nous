defmodule Nous.CodeRuntime.JS.Prelude do
  @moduledoc false

  # The JavaScript that runs before any model-authored code, and the reason the
  # tyrex provider is safe to hand a program written by a model.
  #
  # Every line here was settled by measuring the substrate rather than reading
  # its docs. The findings that shaped it, so a later editor does not "simplify"
  # one of them back out:
  #
  #   * `delete globalThis.Tyrex` breaks the REPLY path. tyrex resolves a bridge
  #     promise by executing `Tyrex._applyReply(...)` inside the isolate, and
  #     that function reads `Tyrex._applications` through the global NAME, not a
  #     closure. Deleting the object makes every bridge call hang forever.
  #     Measured: all four calls in a three-tool program rejected with
  #     "Cannot read properties of undefined (reading '_applyReply')".
  #     So the removal is surgical - `apply` goes, the object stays.
  #
  #   * The gateway cannot be re-acquired once `apply` is gone. Verified against
  #     every route: `import("ext:core/ops")` is a TypeError, `Deno.core`,
  #     `globalThis.__bootstrap` and `new Function("return Deno?.core")()` are
  #     all `undefined`, and `import("node:fs")` is refused. `op_apply` is only
  #     reachable through the property we delete.
  #
  #   * `console.log` writes to the OS file descriptor, not to BEAM IO. The
  #     plan's `Process.group_leader/2` capture cannot see it - measured, the
  #     text appears on the terminal and the eval returns without it. So the
  #     console is re-pointed at the bridge here, which is also what makes logs
  #     survive a killed run: each line is shipped as it happens.
  #
  #   * Bridge calls run INLINE on tyrex's own message loop (documented in
  #     tyrex, and it is deliberate: authorization lives outside the isolate's
  #     blast radius). Two consequences drive the design: a bridge call must
  #     never block, or it suspends the eval deadline and serialises everything;
  #     and tool work must therefore happen in our own processes. Hence the
  #     ticket protocol below - submit returns immediately, and the guest waits
  #     with a JS timer rather than making Elixir wait.
  #
  #   * `setTimeout` does fire while the guest awaits a bridge reply. Measured:
  #     20 rounds of (bridge call + 5ms sleep) in 141ms. That is what makes the
  #     backoff loop legal, and it keeps the deadline exact: a program that only
  #     sleeps is killed at 702ms under a 700ms deadline.

  @global "Tyrex"

  @doc """
  The prelude for one run: bindings, console capture, then gate removal.

  Order is load-bearing. The gateway is captured into a closure and removed
  *before* the program text is reachable, so model-authored code never observes
  a working `Tyrex.apply`.
  """
  @spec render([Nous.CodeRuntime.Binding.t()], String.t(), keyword()) :: String.t()
  def render(bindings, program, opts \\ []) do
    bridge_module = Keyword.fetch!(opts, :bridge_module)
    backoff = Keyword.get(opts, :poll_backoff_ms, [1, 2, 5, 10, 25])

    """
    (async () => {
    #{bridge(bridge_module)}
    #{tickets(backoff)}
    #{globals(bindings)}
    #{console()}
    #{seal()}
    #{body(program)}
    })()
    """
  end

  # One call shape, one allowlisted MFA. The op is chosen here, never by the
  # program: a binding closure is invoked with `{op: "submit"}` and the
  # program's own arguments travel as data underneath it, so no argument can
  # promote itself into a different bridge operation.
  defp bridge(module) do
    """
      const __gate = #{@global}.apply;
      const __rpc = (payload) => __gate("#{module}", "call", [payload]);
    """
  end

  # Submit returns a ticket immediately; the guest waits with its own timer.
  #
  # The backoff escalates because most sub-calls are slower than the first poll
  # and a fixed 1ms interval would spend the run's bridge budget on polling. It
  # is capped rather than unbounded so a slow tool cannot push wake-up latency
  # arbitrarily far out: the cap IS the worst-case delay between a tool
  # finishing and the program seeing it.
  defp tickets(backoff) do
    """
      const __done = new Map();
      const __sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const __backoff = #{Jason.encode!(backoff)};

      const __harvest = (batch) => {
        for (const [id, outcome] of Object.entries(batch)) __done.set(id, outcome);
      };

      // Every bridge reply is checked for `error` before it is trusted to be an
      // answer. Without this a bridge that refused the call - an unregistered
      // runtime, an unknown op, a session that already ended - returns a reply
      // with no `ticket`, and the wait loop below polls a ticket that will
      // never exist until the deadline kills the run. Measured that exact hang
      // before adding it: a run with no session bound spent its whole 40s
      // budget polling instead of reporting in milliseconds.
      const __checked = (reply) => {
        if (reply && reply.error) throw new __ToolError(reply.error);
        return reply;
      };

      const __wait = async (ticket) => {
        let i = 0;
        while (!__done.has(ticket)) {
          const reply = __checked(await __rpc({ op: "poll", tickets: [ticket] }));
          __harvest(reply.done || {});
          if (__done.has(ticket)) break;
          await __sleep(__backoff[Math.min(i++, __backoff.length - 1)]);
        }
        const outcome = __done.get(ticket);
        __done.delete(ticket);
        return outcome;
      };

      const __invoke = async (name, args) => {
        const { ticket } = __checked(await __rpc({ op: "submit", tool: name, args: args ?? {} }));
        const outcome = await __wait(ticket);
        if (outcome.ok) return outcome.value;
        throw new __ToolError(outcome.error);
      };
    """
  end

  # A real named class, so a program can `catch (e) { if (e instanceof ... ) }`
  # in its own idiom - which is what `Binding.error_class` promises. The tool
  # name and message are copied onto the error because that pair is all a
  # program is ever told about a failure.
  defp globals(bindings) do
    class = error_class(bindings)

    definitions =
      Enum.map_join(bindings, "\n", fn binding ->
        entries =
          binding.functions
          |> Map.keys()
          |> Enum.sort()
          |> Enum.map_join(",\n", fn name ->
            ~s|      #{encode(name)}: (args) => __invoke(#{encode(name)}, args)|
          end)

        """
          globalThis[#{encode(binding.global)}] = Object.freeze({
        #{entries}
          });
        """
      end)

    """
      class #{class} extends Error {
        constructor(payload) {
          super((payload && payload.message) || "tool call failed");
          this.name = #{encode(class)};
          this.tool = payload && payload.tool;
        }
      }
      globalThis[#{encode(class)}] = #{class};
      const __ToolError = #{class};

    #{definitions}
    """
  end

  # Both streams are captured, and `console.log` is deliberately NOT awaited:
  # a log line is fire-and-forget so that logging cannot fail a program, and so
  # that a run killed mid-flight has already shipped everything it said. The
  # ledger's byte accounting lives in Elixir, where the program cannot reach it.
  defp console do
    """
      let __logs = 0;
      const __logCount = () => __logs;
      const __fmt = (args) => args.map((a) => {
        if (typeof a === "string") return a;
        try { return JSON.stringify(a) ?? String(a); } catch (_) { return String(a); }
      }).join(" ");
      const __emit = (stream) => (...args) => {
        __logs++;
        __rpc({ op: "log", stream, line: __fmt(args) });
      };
      console.log = __emit("stdout");
      console.info = __emit("stdout");
      console.debug = __emit("stdout");
      console.warn = __emit("stderr");
      console.error = __emit("stderr");
    """
  end

  # Remove the arbitrary-module gateway, then pin what tyrex still needs.
  #
  # `apply` is redefined as non-configurable `undefined` rather than deleted so
  # the program cannot put a property back in its place. `_applyReply` and
  # `_applications` are pinned as non-configurable while keeping the SAME
  # objects, because `_applications` must stay a mutable map for replies to
  # resolve - `Object.freeze` here would break the bridge. The binding itself is
  # pinned last so `globalThis.Tyrex = {...}` cannot rebind the name.
  #
  # None of the pins are a security boundary; the boundary is that `op_apply` is
  # unreachable once `apply` is gone. They exist because without them a program
  # can break its own reply path and turn a fast failure into a full-deadline
  # hang, which costs the operator wall clock and tells them nothing.
  #
  # A program CAN still forge a resolution for its own pending call by walking
  # `_applications` - it would be deceiving only itself. Real dispatch, the
  # permission decision and the audit record all happen in Elixir, so a forged
  # reply cannot cause a tool to run or a denied tool to be reached.
  defp seal do
    """
      Object.defineProperty(#{@global}, "apply", {
        value: undefined, writable: false, configurable: false
      });
      for (const key of ["_applyReply", "_applications"]) {
        Object.defineProperty(#{@global}, key, {
          value: #{@global}[key], writable: false, configurable: false
        });
      }
      Object.defineProperty(globalThis, "#{@global}", {
        value: #{@global}, writable: false, configurable: false
      });
    """
  end

  # The program runs inside its own async function so top-level `await` and
  # `return` both work, which is how the SDK tells the model to write it.
  #
  # `logs` reports the count rather than the lines: the lines are already in
  # Elixir, streamed as they happened, and shipping them twice would double the
  # byte cost of the very output we are trying to bound. The count is what lets
  # the session know whether it has seen everything the program said before it
  # builds the result.
  #
  # The thrown value is unpacked HERE, in the guest, because an `Error` does not
  # survive the trip: `JSON.stringify(new Error("model bug"))` is `{}`, so a
  # program that threw arrived on the Elixir side as `%{}` and the model was
  # told its program failed without being told what it said. Measured before
  # this existed - the message was literally `"%{}"`.
  #
  # `String(e)` is the fallback because `throw "boom"` and `throw {code: 1}` are
  # legal JavaScript and a model writing a program will do both.
  defp body(program) do
    """
      const __main = async () => {
    #{program}
      };
      try {
        const __value = await __main();
        return { ok: true, value: __value === undefined ? null : __value, logs: __logCount() };
      } catch (e) {
        const __name = (e && e.name) || "Error";
        const __message = (e && e.message) || String(e);
        return {
          ok: false,
          error: { name: __name, message: __message, tool: (e && e.tool) || null },
          logs: __logCount()
        };
      }
    """
  end

  defp error_class([%{error_class: class} | _]) when is_binary(class) and class != "", do: class
  defp error_class(_bindings), do: "ToolError"

  # JSON encoding, not interpolation: a tool name is model-visible data and can
  # contain a quote, a backslash, a newline or a line separator. `Jason` escapes
  # all of them, and `\u2028`/`\u2029` too, which are valid in JSON strings but
  # terminate a JavaScript line.
  defp encode(value), do: Jason.encode!(value, escape: :javascript_safe)
end
