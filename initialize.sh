#!/bin/bash
set -e

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "uv not found! Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    source ~/.bashrc
fi

# Create Python virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo "Creating Python virtual environment with uv..."
    uv venv .venv
fi

# Activate the virtual environment
source .venv/bin/activate

# Install dependencies with uv
echo "Installing dependencies with uv..."
uv pip install -r requirements.txt

# Install Ansible Galaxy requirements
echo "Installing Ansible Galaxy collections..."
ansible-galaxy collection install community.general
ansible-galaxy collection install community.postgresql

echo "Environment initialized successfully!"
echo "To activate the environment, run: source .venv/bin/activate"
