HALO LAB
========
Local AI dashboard for the GMKtec EVO-X2 (Ryzen AI Max+ 395, 96 GB).
Download, chat with, compare and benchmark local AI models, and watch the
CPU, GPU and NPU work in real time. Everything stays on this computer.

GETTING STARTED
1. Double-click the Halo Lab icon on the Desktop (or "Start Halo Lab.bat").
   An orange ring appears near the clock and Halo Lab opens in your browser.
2. Press "Set up the engine" (one time, about 35 MB).
3. Pick your first model. Qwen3 30B-A3B is the recommended start.
4. Chat. The model loads into the GPU by itself.

Nothing else to install: no Ollama, no command line.
To quit, right-click the orange ring > Quit Halo Lab.

BIG MODELS
The engine can use about 76-80 GB on a 96 GB EVO-X2 with default settings
(set-aside GPU memory plus shared memory), enough for gpt-oss 120B.
Halo Lab reads the real amount from your PC.

WHERE THINGS GO
Engine and models: %LOCALAPPDATA%\HaloLab (change the models folder in Setup).

The NPU reading 0% while chatting is normal: models run on the GPU.
To use the NPU, run an NPU or Hybrid model in AMD Lemonade Server.
Ollama, LM Studio and Lemonade still work as optional engines (top right).
Full details are in README.md.
