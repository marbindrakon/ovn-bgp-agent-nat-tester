#!/usr/bin/env python3
"""
SNAT Test Heartbeat Dashboard
Receives heartbeats from test instances and displays their status.
Permanent instances (test-*) are never removed from the state file.
Ephemeral instances (load-*) are automatically cleaned up after 10 minutes of no heartbeat.
"""

import json
import os
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, render_template

app = Flask(__name__)

# Threshold for stale instances
PERMANENT_STALE_THRESHOLD_SECONDS = 300  # 5 minutes
EPHEMERAL_STALE_THRESHOLD_SECONDS = 180  # 3 minutes
EPHEMERAL_CLEANUP_THRESHOLD_SECONDS = 600  # 10 minutes

# State file path
STATE_FILE = os.environ.get('STATE_FILE', '/tmp/heartbeat-state.json')


def get_instance_type(hostname):
    """Determine instance type from hostname pattern."""
    if hostname.startswith('test-'):
        return 'permanent'
    elif hostname.startswith('load-'):
        return 'ephemeral'
    return 'unknown'


def get_stale_threshold(instance_type):
    """Get the appropriate stale threshold for an instance type."""
    if instance_type == 'ephemeral':
        return EPHEMERAL_STALE_THRESHOLD_SECONDS
    return PERMANENT_STALE_THRESHOLD_SECONDS


def load_state():
    """Load state from JSON file and return instances dict.
    Filters out expired ephemeral instances during load.
    """
    instances = {}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r') as f:
                data = json.load(f)
                now = datetime.utcnow()
                cleanup_threshold = timedelta(seconds=EPHEMERAL_CLEANUP_THRESHOLD_SECONDS)

                for instance_id, instance_data in data.items():
                    instance_data['last_seen'] = datetime.fromisoformat(instance_data['last_seen'])
                    instance_data['first_seen'] = datetime.fromisoformat(instance_data['first_seen'])

                    # Filter out expired ephemeral instances
                    instance_type = get_instance_type(instance_data.get('hostname', ''))
                    if instance_type == 'ephemeral':
                        time_since_last_seen = now - instance_data['last_seen']
                        if time_since_last_seen > cleanup_threshold:
                            app.logger.info(f"Filtered expired ephemeral instance: {instance_data.get('hostname')} (last seen {time_since_last_seen.total_seconds()}s ago)")
                            continue

                    instances[instance_id] = instance_data
        except (json.JSONDecodeError, KeyError, ValueError, IOError) as e:
            app.logger.warning(f"Failed to load state file: {e}")
    return instances


def save_state(instances):
    """Save state to JSON file.
    Cleans up expired ephemeral instances before saving.
    """
    try:
        now = datetime.utcnow()
        cleanup_threshold = timedelta(seconds=EPHEMERAL_CLEANUP_THRESHOLD_SECONDS)
        data = {}

        for instance_id, instance_data in instances.items():
            # Filter out expired ephemeral instances
            instance_type = get_instance_type(instance_data.get('hostname', ''))
            if instance_type == 'ephemeral':
                time_since_last_seen = now - instance_data['last_seen']
                if time_since_last_seen > cleanup_threshold:
                    app.logger.info(f"Cleaned up expired ephemeral instance: {instance_data.get('hostname')} (last seen {time_since_last_seen.total_seconds()}s ago)")
                    continue

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
    hostname = data.get('hostname', 'unknown')
    instance_type = get_instance_type(hostname)

    instances[instance_id] = {
        'instance_id': instance_id,
        'hostname': hostname,
        'ip_address': data.get('ip_address', request.remote_addr),
        'availability_zone': data.get('availability_zone', 'unknown'),
        'vm_type': data.get('vm_type', 'unknown'),
        'instance_type': instance_type,
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

    instance_list = []
    for instance_id, data in instances.items():
        instance_type = data.get('instance_type', get_instance_type(data.get('hostname', '')))
        stale_threshold_seconds = get_stale_threshold(instance_type)
        stale_threshold = now - timedelta(seconds=stale_threshold_seconds)

        is_stale = data['last_seen'] < stale_threshold
        seconds_ago = (now - data['last_seen']).total_seconds()

        instance_list.append({
            'instance_id': instance_id,
            'hostname': data['hostname'],
            'ip_address': data['ip_address'],
            'availability_zone': data['availability_zone'],
            'vm_type': data['vm_type'],
            'instance_type': instance_type,
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
    """API endpoint returning instance data as JSON.
    Optional query parameters:
      - type: Filter by instance type (permanent or ephemeral)
      - hostname_prefix: Filter by hostname prefix
    """
    # Load current state from file
    instances = load_state()

    # Get query parameters
    type_filter = request.args.get('type')
    hostname_prefix = request.args.get('hostname_prefix')

    now = datetime.utcnow()

    instance_list = []
    for instance_id, data in instances.items():
        instance_type = data.get('instance_type', get_instance_type(data.get('hostname', '')))

        # Apply filters
        if type_filter and instance_type != type_filter:
            continue
        if hostname_prefix and not data.get('hostname', '').startswith(hostname_prefix):
            continue

        stale_threshold_seconds = get_stale_threshold(instance_type)
        stale_threshold = now - timedelta(seconds=stale_threshold_seconds)

        is_stale = data['last_seen'] < stale_threshold
        seconds_ago = (now - data['last_seen']).total_seconds()

        instance_list.append({
            'instance_id': instance_id,
            'hostname': data['hostname'],
            'ip_address': data['ip_address'],
            'availability_zone': data['availability_zone'],
            'vm_type': data['vm_type'],
            'instance_type': instance_type,
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
