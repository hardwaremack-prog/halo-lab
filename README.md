# Halo Lab

<img src="halo-lab-icon.png" alt="Halo Lab icon" width="96">

A local AI dashboard for AMD **Ryzen AI Max+ 395** ("Strix Halo") mini PCs such as the
GMKtec EVO-X2. These machines share up to 96 GB of fast memory with the Radeon 8060S GPU,
so they can run models no ordinary graphics card can hold, such as gpt-oss 120B and
Llama 4 Scout. Halo Lab gives you one place to download, chat with, compare and benchmark
those models, and to see what the CPU, GPU and NPU are actually doing.

Everything runs on your own computer. Nothing you type leaves it.

![Chat](screenshot-chat.png)

## What's inside

- **Chat**: streaming answers with live tokens per second, saved chats, image input for vision
  models, a collapsible "thought process" for reasoning models, personality presets, and
  controls for temperature, context window (up to 128K) and how long a model stays loaded.
  Every answer also records peak GPU and NPU use.
- **Model Library**: 15 models picked for a 96 GB Strix Halo machine, from a 3B test model up to
  gpt-oss 120B. Each card says whether it fits your GPU memory setting at your context size,
  with an estimated speed and one-click download or delete. Any other Ollama or Hugging Face
  model can be downloaded by name.
- **Arena**: ask 2–4 models the same question side by side and see which is fastest.
- **Running**: what's loaded, how much is on the GPU, and Unload buttons to free memory.
- **Hardware**: live CPU, GPU and **NPU** use with graphs, which programs are using the GPU and
  NPU, GPU memory in use, and whether a model has spilled into slower shared RAM.
- **Benchmark**: real reading and writing speeds on your machine, with peak GPU/NPU use and history.
- **Setup**: works with Ollama (all features), LM Studio, AMD Lemonade Server and llama.cpp server.

![Model Library](screenshot-library.png)

![Hardware](screenshot-hardware.png)

![Benchmark](screenshot-benchmark.png)

![Running](screenshot-running.png)

## Getting started (Windows)

1. Install [Ollama](https://ollama.com/download).
2. Double-click **Start Halo Lab.bat**. It starts the hardware monitor in a minimized window
   and opens the dashboard in your browser.
3. If the engine dot at the top right stays red, run **Fix Ollama connection.bat** once.
   It sets `OLLAMA_ORIGINS` so Ollama accepts requests from the page, then restarts Ollama.
4. Open **Model Library** and download a model. Qwen3 30B-A3B or gpt-oss 20B are good first picks.
5. For the big models, give the GPU more memory in AMD Software (Variable Graphics Memory)
   or the BIOS. 64 GB is a good start on a 96 GB machine.

## Files

| File | What it is |
| --- | --- |
| `Halo Lab.html` | The dashboard. A single page, no install. `index.html` is the same file. |
| `halo-monitor.ps1` | Hardware monitor. Reads the same Windows performance counters Task Manager uses and serves them to the page at `http://localhost:11500/stats`. It only listens on this computer. |
| `Start Halo Lab.bat` | Starts the monitor and opens the dashboard. |
| `Fix Ollama connection.bat` | One-time fix if the page can't reach Ollama. |

## About the NPU

The NPU reading 0% while you chat is normal. Ollama, LM Studio and llama.cpp run models on
the GPU, which is much faster than the NPU for large models. To use the NPU, run AMD Lemonade
Server with a model marked NPU or Hybrid and pick Lemonade at the top right. NPU activity
shows up only on Windows 11 24H2 or newer with AMD's NPU driver installed. If Task Manager
shows an NPU graph, Halo Lab will too.

## Notes

- Screenshots use demo data, not real measurements.
- Model sizes and speeds in the Library are estimates. Use the Benchmark tab for real numbers.
- The model list reflects what was current in mid-2026. Newer models can be downloaded by name.
- Chats and settings are saved in your browser only.
