#!/usr/bin/env python3
"""
SNAT Test Heartbeat Dashboard
Receives heartbeats from test instances and displays their status.
Instances are never automatically removed; use the cleanup scripts or
DELETE /api/instances?hostname_prefix=... to remove them explicitly.
"""

import fcntl
import json
import os
import tempfile
from contextlib import contextmanager
from functools import wraps
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, render_template

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 1 * 1024 * 1024  # 1 MB

# Stale thresholds — scaled for 10s heartbeat interval
PERMANENT_STALE_THRESHOLD_SECONDS = 60   # 6 missed heartbeats
EPHEMERAL_STALE_THRESHOLD_SECONDS = 30   # 3 missed heartbeats

# API key for mutating endpoints (read from environment)
API_KEY = os.environ.get('API_KEY', '')

# Instance limits
MAX_INSTANCES = 500
MAX_RECENT_FAILURES = 20
MAX_FIELD_LENGTHS = {
    'instance_id': 64,
    'hostname': 128,
    'ip_address': 45,
    'availability_zone': 64,
    'vm_type': 32,
    'failure_reason': 256,
}

# State file path
STATE_FILE = os.environ.get('STATE_FILE', '/tmp/heartbeat-state.json')
LOAD_TEST_STATUS_FILE = os.environ.get('LOAD_TEST_STATUS_FILE', '/tmp/load-test-status.json')
LOAD_TEST_HISTORY_FILE = os.environ.get('LOAD_TEST_HISTORY_FILE', '/tmp/load-test-history.json')
STATE_LOCK_FILE = os.environ.get('STATE_LOCK_FILE', '/tmp/heartbeat-state.lock')
MAX_HISTORY_ENTRIES = 5


@contextmanager
def _state_lock():
    """Exclusive file lock to serialize all state mutations across gunicorn workers."""
    with open(STATE_LOCK_FILE, 'w') as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def require_api_key(f):
    """Decorator that rejects requests without a valid X-API-Key header."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if not API_KEY:
            app.logger.warning("API_KEY not configured — mutating endpoint is unprotected")
            return f(*args, **kwargs)
        key = request.headers.get('X-API-Key', '')
        if key != API_KEY:
            return jsonify({'error': 'unauthorized'}), 401
        return f(*args, **kwargs)
    return decorated


def truncate_field(value, field_name):
    """Truncate a string field to its maximum allowed length."""
    max_len = MAX_FIELD_LENGTHS.get(field_name)
    if max_len and isinstance(value, str) and len(value) > max_len:
        return value[:max_len]
    return value


@app.after_request
def set_security_headers(response):
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Content-Security-Policy'] = "default-src 'self'; style-src 'unsafe-inline' 'self'; script-src 'unsafe-inline' 'self'"
    response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    return response


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


def _atomic_write(path, data):
    """Write JSON to a temp file then rename into place (atomic on Linux)."""
    dir_name = os.path.dirname(os.path.abspath(path))
    with tempfile.NamedTemporaryFile('w', dir=dir_name, delete=False, suffix='.tmp') as f:
        json.dump(data, f, indent=2)
        tmp_path = f.name
    os.replace(tmp_path, path)


def save_state(instances):
    """Save state to JSON file atomically."""
    try:
        data = {}
        for instance_id, instance_data in instances.items():
            data[instance_id] = {
                **instance_data,
                'last_seen': instance_data['last_seen'].isoformat(),
                'first_seen': instance_data['first_seen'].isoformat(),
            }
        _atomic_write(STATE_FILE, data)
    except IOError as e:
        app.logger.error(f"Failed to save state file: {e}")


def sanitize_recent_failures(raw):
    """Validate and sanitize recent_failures list from agent payload."""
    if not isinstance(raw, list):
        return []
    result = []
    for entry in raw[:MAX_RECENT_FAILURES]:
        if not isinstance(entry, dict):
            continue
        ts = entry.get('timestamp', '')
        reason = entry.get('reason', '')
        if isinstance(ts, str) and isinstance(reason, str):
            result.append({
                'timestamp': ts[:32],
                'reason': reason[:MAX_FIELD_LENGTHS['failure_reason']],
            })
    return result


@app.route('/healthz')
def healthz():
    """Health check endpoint for Kubernetes."""
    return jsonify({'status': 'healthy'}), 200


@app.route('/heartbeat', methods=['POST'])
@require_api_key
def heartbeat():
    """Receive heartbeat from an instance."""
    data = request.get_json() or {}

    instance_id = data.get('instance_id') or request.headers.get('X-Instance-ID')
    if not instance_id:
        return jsonify({'error': 'instance_id required'}), 400

    instance_id = truncate_field(instance_id, 'instance_id')

    now = datetime.utcnow()
    hostname = truncate_field(data.get('hostname', 'unknown'), 'hostname')
    instance_type = get_instance_type(hostname)

    with _state_lock():
        instances = load_state()

        if instance_id not in instances and len(instances) >= MAX_INSTANCES:
            return jsonify({'error': 'instance limit reached'}), 429

        existing = instances.get(instance_id, {})

        instances[instance_id] = {
            'instance_id': instance_id,
            'hostname': hostname,
            'ip_address': truncate_field(data.get('ip_address', request.remote_addr), 'ip_address'),
            'availability_zone': truncate_field(data.get('availability_zone', 'unknown'), 'availability_zone'),
            'vm_type': truncate_field(data.get('vm_type', 'unknown'), 'vm_type'),
            'instance_type': instance_type,
            'last_seen': now,
            'first_seen': existing.get('first_seen', now),
            'failure_count': int(data['failure_count']) if isinstance(data.get('failure_count'), (int, float)) else 0,
            'recent_failures': sanitize_recent_failures(data.get('recent_failures', [])),
        }

        save_state(instances)

    return jsonify({'status': 'ok', 'timestamp': now.isoformat()}), 200


def _build_instance_view(instance_id, data, now):
    """Build the dict representation of an instance for API/dashboard use."""
    instance_type = data.get('instance_type', get_instance_type(data.get('hostname', '')))
    stale_threshold_seconds = get_stale_threshold(instance_type)
    stale_threshold = now - timedelta(seconds=stale_threshold_seconds)

    is_stale = data['last_seen'] < stale_threshold
    seconds_ago = (now - data['last_seen']).total_seconds()
    is_warning = not is_stale and seconds_ago > (stale_threshold_seconds * 0.5)

    return {
        'instance_id': instance_id,
        'hostname': data['hostname'],
        'ip_address': data['ip_address'],
        'availability_zone': data['availability_zone'],
        'vm_type': data['vm_type'],
        'instance_type': instance_type,
        'first_seen': data['first_seen'].isoformat(),
        'last_seen': data['last_seen'].isoformat(),
        'seconds_ago': int(seconds_ago),
        'is_stale': is_stale,
        'is_warning': is_warning,
        'failure_count': data.get('failure_count', 0),
        'recent_failures': data.get('recent_failures', []),
    }


@app.route('/')
def dashboard():
    """Render the dashboard showing instance status."""
    instances = load_state()
    now = datetime.utcnow()

    instance_list = [_build_instance_view(iid, d, now) for iid, d in instances.items()]
    instance_list.sort(key=lambda x: (x['availability_zone'], x['vm_type'], x['instance_id']))

    permanent = [i for i in instance_list if i['instance_type'] == 'permanent']
    ephemeral = [i for i in instance_list if i['instance_type'] == 'ephemeral']

    lt_status = load_test_status()
    test_history = load_test_history()

    return render_template('dashboard.html',
                          instances=instance_list,
                          total_count=len(instance_list),
                          stale_count=sum(1 for i in instance_list if i['is_stale']),
                          healthy_count=sum(1 for i in instance_list if not i['is_stale']),
                          perm_total=len(permanent),
                          perm_healthy=sum(1 for i in permanent if not i['is_stale']),
                          perm_stale=sum(1 for i in permanent if i['is_stale']),
                          eph_total=len(ephemeral),
                          eph_healthy=sum(1 for i in ephemeral if not i['is_stale']),
                          eph_stale=sum(1 for i in ephemeral if i['is_stale']),
                          load_test=lt_status,
                          test_history=test_history)


@app.route('/clear', methods=['POST'])
@require_api_key
def clear_state():
    """Clear all heartbeat state."""
    try:
        with _state_lock():
            if os.path.exists(STATE_FILE):
                os.remove(STATE_FILE)
        app.logger.info("State cleared manually")
        return jsonify({'status': 'cleared'}), 200
    except IOError as e:
        app.logger.error(f"Failed to clear state file: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/api/instances', methods=['DELETE'])
@require_api_key
def delete_instances():
    """Remove instances matching a hostname prefix.

    Query parameters:
      hostname_prefix: Remove instances whose hostname starts with this string (required)
    """
    hostname_prefix = request.args.get('hostname_prefix')
    if not hostname_prefix:
        return jsonify({'error': 'hostname_prefix query parameter required'}), 400

    with _state_lock():
        instances = load_state()
        removed = []
        kept = {}
        for instance_id, data in instances.items():
            if data.get('hostname', '').startswith(hostname_prefix):
                removed.append(data.get('hostname', instance_id))
            else:
                kept[instance_id] = data

        save_state(kept)

    app.logger.info(f"Removed {len(removed)} instances matching prefix '{hostname_prefix}': {removed}")
    return jsonify({'status': 'ok', 'removed_count': len(removed), 'removed': removed}), 200


@app.route('/api/instances/<instance_id>')
def get_instance(instance_id):
    """Return full details for a single instance including failure history."""
    instances = load_state()
    data = instances.get(instance_id)
    if data is None:
        return jsonify({'error': 'not found'}), 404
    now = datetime.utcnow()
    return jsonify(_build_instance_view(instance_id, data, now)), 200


@app.route('/api/instances')
def api_instances():
    """API endpoint returning instance data as JSON.
    Optional query parameters:
      - type: Filter by instance type (permanent or ephemeral)
      - hostname_prefix: Filter by hostname prefix
    """
    instances = load_state()

    type_filter = request.args.get('type')
    hostname_prefix = request.args.get('hostname_prefix')

    now = datetime.utcnow()

    instance_list = []
    for instance_id, data in instances.items():
        instance_type = data.get('instance_type', get_instance_type(data.get('hostname', '')))

        if type_filter and instance_type != type_filter:
            continue
        if hostname_prefix and not data.get('hostname', '').startswith(hostname_prefix):
            continue

        instance_list.append(_build_instance_view(instance_id, data, now))

    return jsonify({
        'instances': instance_list,
        'total_count': len(instance_list),
        'stale_count': sum(1 for i in instance_list if i['is_stale']),
        'healthy_count': sum(1 for i in instance_list if not i['is_stale']),
    })


def load_test_status():
    """Load the current load test status from file."""
    default = {'status': 'idle', 'iteration': 0, 'max_iterations': 0,
               'failed_vms': [], 'started_at': None, 'updated_at': None,
               'phase': '', 'test_mode': ''}
    if os.path.exists(LOAD_TEST_STATUS_FILE):
        try:
            with open(LOAD_TEST_STATUS_FILE, 'r') as f:
                data = json.load(f)
                merged = {**default, **data}
                if merged.get('started_at'):
                    start = datetime.fromisoformat(merged['started_at'])
                    if merged['status'] == 'running':
                        end = datetime.utcnow()
                    elif merged.get('updated_at'):
                        end = datetime.fromisoformat(merged['updated_at'])
                    else:
                        end = start
                    merged['elapsed_seconds'] = int((end - start).total_seconds())
                else:
                    merged['elapsed_seconds'] = 0
                return merged
        except (json.JSONDecodeError, IOError):
            pass
    return {**default, 'elapsed_seconds': 0}


def save_test_status(data):
    """Save load test status to file atomically."""
    try:
        data['updated_at'] = datetime.utcnow().isoformat()
        _atomic_write(LOAD_TEST_STATUS_FILE, data)
    except IOError as e:
        app.logger.error(f"Failed to save load test status: {e}")


def load_test_history():
    """Load the test run history from file."""
    if os.path.exists(LOAD_TEST_HISTORY_FILE):
        try:
            with open(LOAD_TEST_HISTORY_FILE, 'r') as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return []


def save_to_test_history(entry):
    """Prepend a completed/failed test run to the history file (max 5 entries)."""
    history = load_test_history()
    history.insert(0, entry)
    history = history[:MAX_HISTORY_ENTRIES]
    try:
        _atomic_write(LOAD_TEST_HISTORY_FILE, history)
    except IOError as e:
        app.logger.error(f"Failed to save test history: {e}")


@app.route('/api/load-test/status', methods=['GET'])
def get_load_test_status():
    """Get the current load test status."""
    return jsonify(load_test_status()), 200


@app.route('/api/load-test/status', methods=['POST'])
@require_api_key
def update_load_test_status():
    """Update the load test status."""
    data = request.get_json() or {}
    status = data.get('status')
    if status not in ('running', 'completed', 'failed', 'idle'):
        return jsonify({'error': 'status must be running, completed, failed, or idle'}), 400

    with _state_lock():
        current = load_test_status()
        previous_status = current.get('status')

        current['status'] = status
        if 'iteration' in data:
            current['iteration'] = data['iteration']
        if 'max_iterations' in data:
            current['max_iterations'] = data['max_iterations']
        if 'phase' in data:
            current['phase'] = data['phase']
        if 'test_mode' in data:
            current['test_mode'] = data['test_mode']

        history_status = None
        if status in ('completed', 'failed'):
            history_status = status
        elif status == 'idle' and previous_status == 'running':
            history_status = 'cancelled'

        if history_status:
            elapsed = 0
            if current.get('started_at'):
                start = datetime.fromisoformat(current['started_at'])
                elapsed = int((datetime.utcnow() - start).total_seconds())
            save_to_test_history({
                'status': history_status,
                'test_mode': current.get('test_mode', ''),
                'iteration': current.get('iteration', 0),
                'max_iterations': current.get('max_iterations', 0),
                'started_at': current.get('started_at', ''),
                'finished_at': datetime.utcnow().isoformat(),
                'elapsed_seconds': elapsed,
                'failed_vms': current.get('failed_vms', []),
                'phase': current.get('phase', ''),
            })

        if status == 'running':
            if previous_status != 'running':
                current['started_at'] = datetime.utcnow().isoformat()
            current['failed_vms'] = []
        elif status == 'failed':
            current['failed_vms'] = data.get('failed_vms', [])
        elif status == 'idle':
            current['started_at'] = None
            current['failed_vms'] = []
            current['phase'] = ''
            current['test_mode'] = ''

        save_test_status(current)

    return jsonify({'status': 'ok'}), 200


if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port)
