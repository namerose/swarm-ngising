#!/bin/bash

set -euo pipefail

# General arguments
ROOT=$PWD

# Default port for modal-login server, can be changed by setting the PORT environment variable
DEFAULT_PORT=3000
PORT=${PORT:-$DEFAULT_PORT}

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes

# Check if public multi-address is given else set to default
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

# Check if peer multi-address is given else set to default
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ" # gensyn coordinator node
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

# Check if host multi-address is given else set to default
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
# Remove this file if you want a new PeerID.
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

# Will ignore any visible GPUs if set.
CPU_ONLY=${CPU_ONLY:-""}

# Set if successfully parsed from modal-login/temp-data/userData.json.
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# Function to clean up the server process upon exit
cleanup() {
    echo_green ">> Shutting down trainer..."

    # Remove modal credentials if they exist
    rm -r $ROOT_DIR/modal-login/temp-data/*.json 2> /dev/null || true

    # Explicitly kill ngrok and cloudflared if they exist
    if [ -n "${NGROK_PID:-}" ]; then
        kill $NGROK_PID 2> /dev/null || true
        echo "Stopped ngrok tunnel"
    fi
    
    if [ -n "${CLOUDFLARED_PID:-}" ]; then
        kill $CLOUDFLARED_PID 2> /dev/null || true
        echo "Stopped cloudflare tunnel"
    fi
    
    # Kill all processes belonging to this script's process group
    kill -- -$$ || true

    exit 0
}

trap cleanup EXIT

while true; do
    echo -en $GREEN_TEXT
    read -p ">> Would you like to connect to the Testnet? [Y/n] " yn
    echo -en $RESET_TEXT
    yn=${yn:-Y}  # Default to "Y" if the user presses Enter
    case $yn in
        [Yy]*)  CONNECT_TO_TESTNET=True && break ;;
        [Nn]*)  CONNECT_TO_TESTNET=False && break ;;
        *)  echo ">>> Please answer yes or no." ;;
    esac
done

if [ "$CONNECT_TO_TESTNET" = "True" ]; then
    # Run modal_login server.
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login
    # Check if the yarn command exists; if not, install Yarn.
    # Temporarily disable strict error checking when sourcing .bashrc
    set +eu
    source ~/.bashrc
    set -eu

    # Node.js + NVM setup
    if ! command -v node >/dev/null 2>&1; then
        echo "Node.js not found. Installing NVM and latest Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
       nvm install node
    else
        echo "Node.js is already installed: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        # Detect Ubuntu (including WSL Ubuntu) and install Yarn accordingly
        if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
            echo "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
            curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
            echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            sudo apt update && sudo apt install -y yarn
        else
            echo "Yarn is not installed. Installing Yarn..."
            curl -o- -L https://yarnpkg.com/install.sh | sh
            echo 'export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH"' >> ~/.bashrc
            source ~/.bashrc
        fi
    fi
    
    # Set custom port for Next.js server
    echo "Using port $PORT for modal login server"
    export PORT
    
    yarn install
    yarn dev > /dev/null 2>&1 & # Run in background and suppress output

    SERVER_PID=$!  # Store the process ID
    echo "Started server process: $SERVER_PID"
    sleep 5
    
    # Ask user which public tunnel service to use
    echo -en $GREEN_TEXT
    echo ">> How would you like to access the login server?"
    echo "1) Localhost (default)"
    echo "2) Ngrok tunnel"
    echo "3) Cloudflare tunnel"
    read -p "Enter choice [1-3]: " tunnel_choice
    echo -en $RESET_TEXT
    tunnel_choice=${tunnel_choice:-1}  # Default to 1 if the user presses Enter
    
    case $tunnel_choice in
        1)  
            LOGIN_URL="http://localhost:$PORT"
            ;;
        2)  
            if ! command -v ngrok &> /dev/null; then
                echo "ngrok not found. Installing ngrok..."
                curl -s https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
                echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
                sudo apt update && sudo apt install -y ngrok
            fi
            
            # Run ngrok to create a tunnel
            echo "Starting ngrok tunnel to port $PORT..."
            ngrok http $PORT > /dev/null 2>&1 &
            NGROK_PID=$!
            
            # Wait for ngrok to start and get the public URL
            sleep 5
            NGROK_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"[^"]*' | grep -o 'http[^"]*')
            
            if [ -n "$NGROK_URL" ]; then
                LOGIN_URL="$NGROK_URL"
                echo "ngrok tunnel created!"
            else
                echo "Failed to create ngrok tunnel. Using localhost URL."
                LOGIN_URL="http://localhost:$PORT"
            fi
            ;;
        3)  
            if ! command -v cloudflared &> /dev/null; then
                echo "cloudflared not found. Installing cloudflared..."
                curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
                sudo dpkg -i cloudflared.deb
                rm cloudflared.deb
            fi
            
            # Run cloudflared to create a tunnel
            echo "Starting cloudflare tunnel to port $PORT..."
            TUNNEL_LOGFILE="cloudflared.log"
            cloudflared tunnel --url "http://localhost:$PORT" > "$TUNNEL_LOGFILE" 2>&1 &
            CLOUDFLARED_PID=$!
            
            # Wait for cloudflared to start and get the public URL
            sleep 5
            
            # Extract URL from logfile (e.g., "https://chair-polyester-principle-initially.trycloudflare.com")
            CLOUDFLARE_URL=$(grep -o 'https://[^ ]*\.trycloudflare\.com' "$TUNNEL_LOGFILE" | head -1)
            
            if [ -n "$CLOUDFLARE_URL" ]; then
                LOGIN_URL="$CLOUDFLARE_URL"
                echo "Cloudflare tunnel created!"
            else
                echo "Failed to create Cloudflare tunnel. Using localhost URL."
                LOGIN_URL="http://localhost:$PORT"
            fi
            ;;
        *)  
            echo "Invalid choice. Using localhost."
            LOGIN_URL="http://localhost:$PORT"
            ;;
    esac
    
    echo ""
    echo "====================================================================="
    echo -e "${GREEN_TEXT}>> Please open this URL in your browser to login: ${LOGIN_URL}${RESET_TEXT}"
    echo "====================================================================="
    echo ""
    
    # Try different browser open commands, but don't worry if they fail
    if [ -n "${BROWSER:-}" ]; then
        # Try to use BROWSER env var if set
        $BROWSER "$LOGIN_URL" > /dev/null 2>&1 || true
    elif command -v xdg-open > /dev/null 2>&1; then
        xdg-open "$LOGIN_URL" > /dev/null 2>&1 || true
    elif command -v gnome-open > /dev/null 2>&1; then
        gnome-open "$LOGIN_URL" > /dev/null 2>&1 || true
    elif command -v sensible-browser > /dev/null 2>&1; then
        sensible-browser "$LOGIN_URL" > /dev/null 2>&1 || true
    fi
    cd ..

    echo_green ">> Waiting for modal userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 5  # Wait for 5 seconds before checking again
    done
    echo "Found userData.json. Proceeding..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "Your ORG_ID is set to: $ORG_ID"

    # Wait until the API key is activated by the client
    echo "Waiting for API key to become activated..."
    while true; do
        STATUS=$(curl -s "http://localhost:$PORT/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "API key is activated! Proceeding..."
            break
        else
            echo "Waiting for API key to be activated..."
            sleep 5
        fi
    done
fi

pip_install() {
    pip install --disable-pip-version-check -q -r "$1"
}

echo_green ">> Getting requirements..."
pip_install "$ROOT"/requirements-hivemind.txt
pip_install "$ROOT"/requirements.txt

# Install the correct jinja2 version needed for chat templates
echo_green ">> Installing additional dependencies..."
pip install -q --disable-pip-version-check "jinja2>=3.1.0"

if ! command -v nvidia-smi &> /dev/null; then
    # You don't have a NVIDIA GPU
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
elif [ -n "$CPU_ONLY" ]; then
    # ... or we don't want to use it
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
else
    # NVIDIA GPU found
    pip_install "$ROOT"/requirements_gpu.txt
    CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
fi

echo_green ">> Done!"

HF_TOKEN=${HF_TOKEN:-""}
if [ -n "${HF_TOKEN}" ]; then # Check if HF_TOKEN is already set and use if so. Else give user a prompt to choose.
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    echo -en $GREEN_TEXT
    read -p ">> Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N] " yn
    echo -en $RESET_TEXT
    yn=${yn:-N} # Default to "N" if the user presses Enter
    case $yn in
        [Yy]*) read -p "Enter your Hugging Face access token: " HUGGINGFACE_ACCESS_TOKEN ;;
        [Nn]*) HUGGINGFACE_ACCESS_TOKEN="None" ;;
        *) echo ">>> No answer was given, so NO models will be pushed to Hugging Face Hub" && HUGGINGFACE_ACCESS_TOKEN="None" ;;
    esac
fi

echo_green ">> Good luck in the swarm!"
echo_blue ">> Post about rl-swarm on X/twitter! --> https://tinyurl.com/swarmtweet"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

if [ -n "$ORG_ID" ]; then
    # Try different Python command variants
    PYTHON_CMD="python3"
    if ! command -v $PYTHON_CMD > /dev/null 2>&1; then
        PYTHON_CMD="python"
        if ! command -v $PYTHON_CMD > /dev/null 2>&1; then
            echo "Error: Neither python3 nor python commands were found. Please install Python."
            exit 1
        fi
    fi
    
    $PYTHON_CMD -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --config "$CONFIG_PATH"
else
    # Try different Python command variants
    PYTHON_CMD="python3"
    if ! command -v $PYTHON_CMD > /dev/null 2>&1; then
        PYTHON_CMD="python"
        if ! command -v $PYTHON_CMD > /dev/null 2>&1; then
            echo "Error: Neither python3 nor python commands were found. Please install Python."
            exit 1
        fi
    fi
    
    $PYTHON_CMD -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH"
fi

wait  # Keep script running until Ctrl+C
