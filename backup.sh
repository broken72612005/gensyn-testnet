#!/bin/bash

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NC='\033[0m'

print_message() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_message "Checking and installing dependencies (nc and lsof)..."

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if ! command -v nc &> /dev/null || ! command -v lsof &> /dev/null; then
        print_message "Installing netcat and lsof..."
        sudo apt-get update
        sudo apt-get install -y netcat lsof
        if ! command -v nc &> /dev/null || ! command -v lsof &> /dev/null; then
            print_error "Failed to install netcat or lsof. Please install them manually."
            exit 1
        fi
        print_success "Dependencies installed successfully."
    else
        print_success "Dependencies already installed."
    fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
    if ! command -v nc &> /dev/null || ! command -v lsof &> /dev/null; then
        if command -v brew &> /dev/null; then
            print_message "Installing netcat and lsof via Homebrew..."
            brew install netcat lsof
        else
            print_error "Homebrew not found. Please install netcat and lsof manually."
            exit 1
        fi
        if ! command -v nc &> /dev/null || ! command -v lsof &> /dev/null; then
            print_error "Failed to install netcat or lsof. Please install them manually."
            exit 1
        fi
        print_success "Dependencies installed successfully."
    else
        print_success "Dependencies already installed."
    fi
else
    print_warning "Unsupported OS for automatic dependency installation. Ensure nc and lsof are installed."
fi

print_message "Checking rl-swarm directory..."

if [[ $(basename "$PWD") == "rl-swarm" ]]; then
    print_success "Currently in rl-swarm directory."
    RL_SWARM_DIR="$PWD"
else
    print_warning "Not in rl-swarm directory. Checking HOME directory..."
    
    if [[ -d "$HOME/rl-swarm" ]]; then
        print_success "Found rl-swarm directory in HOME."
        RL_SWARM_DIR="$HOME/rl-swarm"
    else
        print_error "rl-swarm directory not found in current directory or HOME."
        exit 1
    fi
fi

cd "$RL_SWARM_DIR" &> /dev/null

print_message "Checking ngrok..."

if ! command -v ngrok &> /dev/null; then
    print_message "Installing ngrok..."
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        curl -s https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
        echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | sudo tee /etc/apt/sources.list.d/ngrok.list
        sudo apt update && sudo apt install ngrok -y
    else
        print_error "Unsupported architecture for auto-install. Install ngrok manually."
        exit 1
    fi
else
    print_success "ngrok is already installed."
fi

if [[ -z "$NGROK_AUTHTOKEN" ]]; then
    read -p "Enter your Ngrok Auth Token: " NGROK_AUTHTOKEN
    ngrok config add-authtoken "$NGROK_AUTHTOKEN"
fi

print_message "Checking python3..."

if command -v python3 &> /dev/null; then
    print_success "python3 is already installed."
else
    print_message "Installing python3..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        sudo apt-get update
        sudo apt-get install -y python3 python3-pip
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &> /dev/null; then
            brew install python
        else
            print_error "Homebrew not found. Please install python3 manually."
            exit 1
        fi
    else
        print_error "Unsupported operating system: $OSTYPE"
        exit 1
    fi
    
    if command -v python3 &> /dev/null; then
        print_success "python3 installation completed successfully."
    else
        print_error "Failed to install python3. Please install it manually."
        exit 1
    fi
fi

print_message "Starting HTTP server..."

PORT=8000
MAX_RETRIES=10
RETRY_COUNT=0
SERVER_STARTED=false

is_port_in_use() {
    if command -v nc &> /dev/null; then
        nc -z localhost "$1" &> /dev/null
        return $?
    elif command -v lsof &> /dev/null; then
        lsof -i:"$1" &> /dev/null
        return $?
    else
        (echo > /dev/tcp/127.0.0.1/"$1") &> /dev/null
        return $?
    fi
}

start_http_server() {
    local port="$1"
    local temp_log="/tmp/http_server_$$.log"
    
    python3 -m http.server "$port" > "$temp_log" 2>&1 &
    local pid=$!
    
    sleep 3
    
    if ps -p $pid > /dev/null; then
        print_success "HTTP server started successfully on port $port."
        echo "$pid"
    else
        if grep -q "Address already in use" "$temp_log"; then
            print_warning "Port $port is already in use."
            return 1
        else
            print_error "Failed to start HTTP server on port $port. Error log:"
            cat "$temp_log"
            return 1
        fi
    fi
}

while [[ $RETRY_COUNT -lt $MAX_RETRIES && $SERVER_STARTED == false ]]; do
    print_message "Attempting to start HTTP server on port $PORT..."
    
    if is_port_in_use "$PORT"; then
        print_warning "Port $PORT is already in use. Trying next port."
        PORT=$((PORT + 1))
        RETRY_COUNT=$((RETRY_COUNT + 1))
        continue
    fi
    
    HTTP_SERVER_PID=$(start_http_server "$PORT")
    
    if [[ -n "$HTTP_SERVER_PID" ]]; then
        print_message "Starting ngrok tunnel to http://localhost:$PORT..."
        ngrok http "$PORT" > /tmp/ngrok_$$.log 2>&1 &
        NGROK_PID=$!

        sleep 10

        TUNNEL_URL=$(curl -s http://127.0.0.1:4040/api/tunnels | grep -o 'https://[^"\,]*')

        if [[ -n "$TUNNEL_URL" ]]; then
            print_success "Ngrok tunnel established at: $TUNNEL_URL"
            SERVER_STARTED=true
        else
            print_error "Failed to establish ngrok tunnel. Trying another port."
            kill $HTTP_SERVER_PID 2>/dev/null
            kill $NGROK_PID 2>/dev/null
            PORT=$((PORT + 1))
            RETRY_COUNT=$((RETRY_COUNT + 1))
        fi
    else
        PORT=$((PORT + 1))
        RETRY_COUNT=$((RETRY_COUNT + 1))
    fi

    echo
    echo -e "${GREEN}${BOLD}========== VPS/GPU/WSL to PC ===========${NC}"
    echo -e "${BOLD}If you want to backup these files from VPS/GPU/WSL to your PC, visit the URLs and download.${NC}"
    echo
    echo -e "${BOLD}1. swarm.pem${NC}"
    echo -e "   ${BLUE}${TUNNEL_URL}/swarm.pem${NC}"
    echo
    echo -e "${BOLD}2. userData.json${NC}"
    echo -e "   ${BLUE}${TUNNEL_URL}/modal-login/temp-data/userData.json${NC}"
    echo
    echo -e "${BOLD}3. userApiKey.json${NC}"
    echo -e "   ${BLUE}${TUNNEL_URL}/modal-login/temp-data/userApiKey.json${NC}"
    echo
    echo -e "${GREEN}${BOLD}======= ONE VPS/GPU/WSL to ANOTHER VPS/GPU/WSL ========${NC}"
    echo -e "${BOLD}To send these files to another VPS/GPU/WSL, use the wget commands instead of the URLs.${NC}"
    echo
    echo -e "${YELLOW}wget -O swarm.pem ${TUNNEL_URL}/swarm.pem${NC}"
    echo -e "${YELLOW}wget -O userData.json ${TUNNEL_URL}/modal-login/temp-data/userData.json${NC}"
    echo -e "${YELLOW}wget -O userApiKey.json ${TUNNEL_URL}/modal-login/temp-data/userApiKey.json${NC}"
    echo
    echo -e "${BLUE}${BOLD}Press Ctrl+C to stop the server when you're done.${NC}"

    # Wait for Ctrl+C
    trap 'echo -e "${YELLOW}Stopping servers...${NC}"; if [[ -n "$HTTP_SERVER_PID" ]]; then kill $HTTP_SERVER_PID 2>/dev/null; fi; if [[ -n "$NGROK_PID" ]]; then kill $NGROK_PID 2>/dev/null; fi; echo -e "${GREEN}Servers stopped.${NC}"' INT
    wait
fi

if [[ $SERVER_STARTED == false ]]; then
    print_error "Failed to start HTTP server after $MAX_RETRIES attempts."
    exit 1
fi
