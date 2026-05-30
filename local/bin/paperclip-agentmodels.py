#!/usr/bin/env python3
"""
CLI utility to list and configure agent models and adapter types for a Paperclip company.

Supports:
  - Listing all agents, their active adapter type, and primary/secondary models.
  - Updating adapter type, primary, and secondary models globally (all agents) or for a specific agent.
  - Resetting models back to default values.

Examples:
  # List all agents, their adapters, and models
  ./paperclip-agentmodels.py

  # Set primary model to gpt-4o for all agents
  ./paperclip-agentmodels.py --primary gpt-4o

  # Set adapter to process for all agents
  ./paperclip-agentmodels.py --adapter process

  # Set primary and secondary models for a specific agent (e.g. Fury)
  ./paperclip-agentmodels.py --agent Fury --primary claude-opus-4-7 --secondary claude-haiku-4-5-20251001
"""

import sys
import os
import json
import argparse
import subprocess

# Resolve the absolute path of the script before changing directory
script_path = os.path.abspath(sys.argv[0])

# Ensure we run from the project root directory
script_dir = os.path.dirname(os.path.abspath(__file__))
os.chdir(os.path.join(script_dir, "../.."))

def load_envrc():
    """Sources the local .envrc file to fetch authentication tokens (1Password/GitHub)."""
    if os.path.exists(".envrc"):
        try:
            # We run bash to source .envrc and output the environment variables
            env_output = subprocess.check_output(
                ["bash", "-c", "source .envrc && env"],
                stderr=subprocess.DEVNULL,
                text=True
            )
            for line in env_output.splitlines():
                if "=" in line:
                    key, val = line.split("=", 1)
                    os.environ[key] = val
        except Exception:
            pass

def load_dotenv():
    """Loads environment variables from .env if they are not already set."""
    if os.path.exists(".env"):
        with open(".env", "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or not line:
                    continue
                if "=" in line:
                    key, val = line.split("=", 1)
                    val = val.strip().strip("'\"")
                    if key not in os.environ:
                        os.environ[key] = val

# Load initial variables from .env
load_dotenv()
company_id = os.environ.get("PAPERCLIP_COMPANY_ID")

# Check if the company ID is a 1Password reference that needs resolving
if company_id and company_id.startswith("op://"):
    load_envrc()
    # Check if 'op' CLI is installed
    op_check = subprocess.run("command -v op", shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if op_check.returncode == 0:
        # Re-execute the script under 'op run' to resolve 1Password references
        cmd = ["op", "run", "--env-file", ".env", "--", "python3", script_path] + sys.argv[1:]
        os.execvp("op", cmd)
    else:
        print("Error: PAPERCLIP_COMPANY_ID contains a 1Password reference, but the 'op' CLI is not available.", file=sys.stderr)
        sys.exit(1)

if not company_id:
    print("Error: PAPERCLIP_COMPANY_ID is not set in the environment or .env file.", file=sys.stderr)
    sys.exit(1)

def fetch_agents():
    """Fetches the list of current agents from the Paperclip API."""
    cmd = ["./local/bin/paperclip-api.sh", "GET", f"/api/companies/{company_id}/agents"]
    res = subprocess.run(cmd, capture_output=True, text=True)
    try:
        data = json.loads(res.stdout)
        if not isinstance(data, list):
            if isinstance(data, dict) and "error" in data:
                print(f"Error from API: {data.get('error')}", file=sys.stderr)
            else:
                print(f"Error: Expected list of agents, got: {data}", file=sys.stderr)
            sys.exit(1)
        return data
    except Exception as e:
        print(f"Error: Failed to parse API response: {e}", file=sys.stderr)
        sys.exit(1)

def list_agents(agents):
    """Prints a formatted table of agents, their adapter types, and active models."""
    print(f"{'Agent Name':18} {'Adapter':15} {'Primary Model':24} {'Cheap/Secondary Model'}")
    print("─" * 80)
    for a in agents:
        if not isinstance(a, dict):
            continue
        cfg = a.get("adapterConfig") or {}
        rt = a.get("runtimeConfig") or {}
        model_profiles = rt.get("modelProfiles") or {}
        
        # Determine cheap model configuration status
        has_cheap = "cheap" in model_profiles
        cheap = model_profiles.get("cheap") or {}
        cheap_ac = cheap.get("adapterConfig") or {}
        
        if not has_cheap:
            cheap_model = "n/a"
        else:
            cheap_model = cheap_ac.get("model") or "default"
            
        primary_model = cfg.get("model") or "default"
        adapter_type = a.get("adapterType") or "n/a"
        print(f"{a.get('name', 'n/a'):18} {adapter_type:15} {primary_model:24} {cheap_model}")

def main():
    # Use RawDescriptionHelpFormatter to preserve the formatting of our docstring/examples
    parser = argparse.ArgumentParser(
        description="List and configure agent models and adapter types for a Paperclip company.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument("--agent", help="Agent name or UUID to update (updates all agents if omitted)")
    parser.add_argument("--adapter", help="Adapter type to set (e.g. claude_local, process)")
    parser.add_argument("--primary", help="Primary model to set (or 'default' to clear)")
    parser.add_argument("--secondary", help="Secondary/cheap model to set (or 'default' to clear)")
    
    args = parser.parse_args()

    agents = fetch_agents()

    # Filter targets based on --agent input
    targets = []
    if args.agent:
        agent_ref = args.agent.strip().lower()
        for a in agents:
            if a.get("name", "").lower() == agent_ref or a.get("id", "").lower() == agent_ref:
                targets.append(a)
        if not targets:
            print(f"Error: Agent '{args.agent}' not found.", file=sys.stderr)
            sys.exit(1)
    else:
        targets = [a for a in agents if isinstance(a, dict)]

    # If no updates are requested, just display the target configuration
    if not args.adapter and not args.primary and not args.secondary:
        list_agents(targets)
        return

    print(f"Updating {len(targets)} agent(s)...")

    # Perform updates via PATCH requests
    for a in targets:
        payload = {}
        
        # Configure adapter type
        if args.adapter:
            payload["adapterType"] = args.adapter

        # Configure primary model
        if args.primary:
            model_val = "" if args.primary == "default" else args.primary
            payload["adapterConfig"] = { "model": model_val }
        
        # Configure secondary/cheap model under runtimeConfig
        if args.secondary:
            model_val = "" if args.secondary == "default" else args.secondary
            rt = a.get("runtimeConfig") or {}
            mp = rt.get("modelProfiles") or {}
            cheap = mp.get("cheap") or {}
            cheap_ac = cheap.get("adapterConfig") or {}
            
            new_cheap = {
                **cheap,
                "enabled": True,
                "adapterConfig": {
                    **cheap_ac,
                    "model": model_val
                }
            }
            new_mp = {
                **mp,
                "cheap": new_cheap
            }
            new_rt = {
                **rt,
                "modelProfiles": new_mp
            }
            payload["runtimeConfig"] = new_rt

        # Run PATCH request using the authenticated paperclip-api.sh tool
        cmd = ["./local/bin/paperclip-api.sh", "PATCH", f"/api/agents/{a['id']}", json.dumps(payload)]
        res = subprocess.run(cmd, capture_output=True, text=True)
        try:
            resp_data = json.loads(res.stdout)
            if isinstance(resp_data, dict) and "error" in resp_data:
                print(f"Error updating agent {a.get('name')}: {resp_data.get('error')}", file=sys.stderr)
                sys.exit(1)
        except Exception as e:
            print(f"Error: Failed to parse update response for {a.get('name')}: {e}", file=sys.stderr)
            sys.exit(1)

    print("Updates completed successfully!\n")
    print("Updated agent configuration:")
    print("────────────────────────────")
    
    # Show only the updated target agents
    updated_agents = fetch_agents()
    updated_targets = []
    for a in updated_agents:
        if any(t["id"] == a["id"] for t in targets):
            updated_targets.append(a)
    list_agents(updated_targets)

if __name__ == "__main__":
    main()
