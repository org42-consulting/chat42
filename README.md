# Chat42

A native AI chat interface for use with local and remote LLMs.

Are you tired of paying monthly subscription fees for AI assistants? Or maybe you just do not want to send your private data, work documents, and ideas to cloud servers?

You might have heard about running AI locally and thought it sounded like something only a hardcore programmer could do. I am here to tell you: forget the complicated guides. Running large language models on your Mac is much easier than you think. Lessons from installing local AI on older and newer Macs show that simpler is always better.

If you have a recent Mac with Apple Silicon (like an M3, M4 or M5 chip), you already own a fantastic machine that is built for AI workloads. You do not need expensive graphics cards or complex coding setups. All you need is **Chat42.**

<img width="912" height="764" alt="Image" src="https://github.com/user-attachments/assets/47fcc1c1-0af9-4c8d-826b-afad644b1edf" />


## Features
Chat42 is a user friendly frontend for AI models that run on your machine or somewhere else (like in the cloud).
- Native MacOS app, providing a smooth and polished user experience
- Supports multiple AI models, allowing to seamlessly switch between models
- Support for English and Dutch languages
- Single interface for connecting to multiple AI models
- Conversation history persistence
- System prompt configuration
- Temperature control for response randomness
- Dark/light mode support

## Quick Start Guide
Want to get started without having to face technical installations? Just follow these steps:
- Download Chat42.
- Open the downloaded DMG file and drag the Chat42. app to your Applications folder
- Doubleclick on the Chat42. icon to open the app
- Click "Settings"
- Select "MLX"
- Download any of the listed models
- When download, click "Load", followed by "Done".
- Start a new converation by clicking the button "New chat"
- Make sure "MLX" is selected in the top bar
- Enter a promppt, such as "Write a haiku about AI"  

<img width="912" height="764" alt="Image" src="https://github.com/user-attachments/assets/f0a16e28-4425-4f42-8c9d-c26e93fb94ce" />


## Supported AI Backends
Chat42. is both user friendly and powerful, and support 3 different kinds of backend, spanning local and cloud models. How cool is that?  
<img width="912" height="764" alt="Image" src="https://github.com/user-attachments/assets/d249f48b-eca1-4053-b075-4753ecf90a9d" />

### 1. Ollama
Ollama is a tool for running large language models locally. It supports various models and allows you to run them on your own machine.

### 2. MLX (Apple Silicon)
MLX is Apple's machine learning framework optimized for Apple Silicon (M1/M2/M3) Macs. It allows for local inference with models downloaded from Hugging Face.

### 3. Gateway
Gateway supports OpenAI-compatible APIs, allowing you to connect to services like OpenAI, LiteLLM, or other compatible services.

## Getting Started

### Prerequisites

- macOS 13 or later (for MLX support)
- For Ollama: Install [Ollama](https://ollama.com/download) on your machine
- For MLX: Running on Apple Silicon (M1/M2/M3) Mac

### Configuration

Access settings through the gear icon in the sidebar or via the Settings menu.

#### General Settings
- **System Prompt**: Configure a system prompt that will be used for all conversations
- **Temperature**: Adjust the randomness of responses (0.0 to 2.0)

#### Ollama Settings
- **Base URL**: Set the URL for your Ollama instance (default: `http://localhost:11434`)
- **Test Connection**: Verify that Ollama is reachable
- **Installed Models**: Shows models available in your Ollama instance

#### Gateway Settings
- **Base URL**: Set the URL for your Gateway service (e.g., `https://api.openai.com`)
- **API Key**: Enter your API key for authentication
- **Test Connection**: Verify that the Gateway service is reachable

#### MLX Settings
- **Model Selection**: Choose from bundled models (Llama 3.2, Mistral, Phi, Gemma, Qwen, etc.)
- **Download**: Download models directly from Hugging Face
- **Load**: Load a downloaded model for use in conversations
- **Unload**: Unload the currently loaded model

## Adding Models

### Ollama Models
1. Ensure Ollama is running on your machine
2. In Settings → Ollama, test the connection to verify Ollama is reachable
3. Use Ollama CLI or web interface to pull models:
   ```
   ollama pull llama3.2
   ollama pull mistral
   ```
4. The app will automatically detect newly pulled models

### MLX Models
1. In Settings → MLX, select a model from the bundled list
2. Click "Download" to download the model from Hugging Face
3. Once downloaded, click "Load" to load the model into memory
4. The model will be ready for use in conversations

### Gateway Models
1. Configure the Gateway URL and API key in Settings → Gateway
2. Test the connection to verify the service is reachable
3. The app will automatically fetch available models from the Gateway service

## Usage

1. Select an AI backend from the sidebar (Ollama, MLX, or Gateway)
2. Choose a model from the available list
3. Start a new conversation by typing in the input field
4. View conversation history in the sidebar
5. Adjust settings as needed through the Settings menu

## Troubleshooting

### Ollama Issues
- Make sure Ollama is running: `ollama serve`
- Verify the Ollama URL in Settings → Ollama
- Check that models are pulled in Ollama

### MLX Issues
- Ensure you're running on Apple Silicon (M1/M2/M3) Mac
- Check that models are downloaded before trying to load them
- Verify sufficient disk space for model downloads

### Gateway Issues
- Verify the Gateway URL and API key in Settings → Gateway
- Check that the service is accessible from your network
- Ensure the API key has proper permissions

## Privacy Policy

Chat42. does not collect or transmit any personal data. All conversations and model usage occur locally on your device. When connecting to external services (like Ollama or API endpoints), data is transmitted according to the privacy policies of those services.



