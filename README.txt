HALO LAB
========
Local AI dashboard for the GMKtec EVO-X2 (Ryzen AI Max+ 395, 96 GB).
Download, chat with, compare and benchmark local AI models, and watch the
CPU, GPU and NPU work in real time. Everything stays on this computer.

1. Install Ollama from ollama.com/download.
2. Double-click "Start Halo Lab.bat" (or the Halo Lab icon on the Desktop).
   It starts the hardware monitor minimized and opens the dashboard.
3. If the engine dot at the top right stays red, run "Fix Ollama connection.bat" once.
4. Model Library tab -> Download a model (Qwen3 30B-A3B or gpt-oss 20B to start).
5. For big models, give the GPU more memory in AMD Software (Variable Graphics
   Memory). 64 GB is a good start.

Tabs: Chat, Arena, Model Library, Running, Hardware, Benchmark, Setup.

The NPU reading 0% while chatting is normal: Ollama and LM Studio use the GPU.
To use the NPU, run an NPU or Hybrid model in AMD Lemonade Server.
NPU activity needs Windows 11 24H2 or newer and AMD's NPU driver.

Also works with LM Studio, AMD Lemonade Server and llama.cpp server.
Chats are saved in your browser only. Full details are in README.md.
