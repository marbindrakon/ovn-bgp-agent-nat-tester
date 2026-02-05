#!/usr/bin/env python3
"""
SNAT Test Heartbeat Dashboard
Receives heartbeats from test instances and displays their status.
Agents are never removed from the state file - staleness is for display only.
"""

import json
import os
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, render_template

app = Flask(__name__)

# Threshold for stale instances (5 minutes)
STALE_THRESHOLD_SECONDS = 300

# State file path
STATE_FILE = os.environ.get('STATE_FILE', '/tmp/heartbeat-state.json')


def load_state():
    """Load state from JSON file and return instances dict."""
    instances = {}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r') as f:
                data = json.load(f)
                for instance_id, instance_data in data.items():
                    instance_data['last_seen'] = datetime.fromisoformat(instance_data['last_seen'])
                    instance_data['first_seen'] = datetime.fromisoformat(instance_data['first_seen'])
                    instances[instance_id] = instance_data
        except (json.JSONDecodeError, KeyError, ValueError, IOError) as e:
            app.logger.warning(f"Failed to load state file: {e}")
    return instances


def save_state(instances):
    """Save state to JSON file."""
    try:
        data = {}
        for instance_id, instance_data in instances.items():
            data[instance_id] = {
                **instance_data,
                'last_seen': instance_data['last_seen'].isoformat(),
                'first_seen': instance_data['first_seen'].isoformat(),
            }
        with open(STATE_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except IOError as e:
        app.logger.error(f"Failed to save state file: {e}")


@app.route('/healthz')
def healthz():
    """Health check endpoint for Kubernetes."""
    return jsonify({'status': 'healthy'}), 200


@app.route('/heartbeat', methods=['POST'])
def heartbeat():
    """Receive heartbeat from an instance."""
    data = request.get_json() or {}

    instance_id = data.get('instance_id') or request.headers.get('X-Instance-ID')
    if not instance_id:
        return jsonify({'error': 'instance_id required'}), 400

    # Load current state from file
    instances = load_state()

    now = datetime.utcnow()
    instances[instance_id] = {
        'instance_id': instance_id,
        'hostname': data.get('hostname', 'unknown'),
        'ip_address': data.get('ip_address', request.remote_addr),
        'availability_zone': data.get('availability_zone', 'unknown'),
        'vm_type': data.get('vm_type', 'unknown'),
        'last_seen': now,
        'first_seen': instances.get(instance_id, {}).get('first_seen', now),
    }

    # Save updated state to file
    save_state(instances)

    return jsonify({'status': 'ok', 'timestamp': now.isoformat()}), 200


@app.route('/')
def dashboard():
    """Render the dashboard showing instance status."""
    # Load current state from file
    instances = load_state()

    now = datetime.utcnow()
    stale_threshold = now - timedelta(seconds=STALE_THRESHOLD_SECONDS)

    instance_list = []
    for instance_id, data in instances.items():
        is_stale = data['last_seen'] < stale_threshold
        seconds_ago = (now - data['last_seen']).total_seconds()

        instance_list.append({
            'instance_id': instance_id,
            'hostname': data['hostname'],
            'ip_address': data['ip_address'],
            'availability_zone': data['availability_zone'],
            'vm_type': data['vm_type'],
            'last_seen': data['last_seen'].isoformat(),
            'seconds_ago': int(seconds_ago),
            'is_stale': is_stale,
        })

    # Sort by availability zone, then by vm_type
    instance_list.sort(key=lambda x: (x['availability_zone'], x['vm_type'], x['instance_id']))

    return render_template('dashboard.html',
                          instances=instance_list,
                          total_count=len(instance_list),
                          stale_count=sum(1 for i in instance_list if i['is_stale']),
                          healthy_count=sum(1 for i in instance_list if not i['is_stale']))


@app.route('/api/instances')
def api_instances():
    """API endpoint returning instance data as JSON."""
    # Load current state from file
    instances = load_state()

    now = datetime.utcnow()
    stale_threshold = now - timedelta(seconds=STALE_THRESHOLD_SECONDS)

    instance_list = []
    for instance_id, data in instances.items():
        is_stale = data['last_seen'] < stale_threshold
        seconds_ago = (now - data['last_seen']).total_seconds()

        instance_list.append({
            'instance_id': instance_id,
            'hostname': data['hostname'],
            'ip_address': data['ip_address'],
            'availability_zone': data['availability_zone'],
            'vm_type': data['vm_type'],
            'last_seen': data['last_seen'].isoformat(),
            'seconds_ago': int(seconds_ago),
            'is_stale': is_stale,
        })

    return jsonify({
        'instances': instance_list,
        'total_count': len(instance_list),
        'stale_count': sum(1 for i in instance_list if i['is_stale']),
        'healthy_count': sum(1 for i in instance_list if not i['is_stale']),
    })


if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port)
