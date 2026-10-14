"""Fake Klipper/Moonraker printer for the print-watch end-to-end check.

Prints "benchy.gcode" for FINISH_AFTER seconds after start, then reports the
job as completed (status + history), like a real printer.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = time.time()
FINISH_AFTER = float(os.environ.get('FINISH_AFTER', '150'))
DURATION = 3600.0


def done():
    return time.time() - START >= FINISH_AFTER


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write('FAKE %.0fs %s\n' % (time.time() - START, fmt % args))

    def do_GET(self):
        if self.path.startswith('/printer/objects/query'):
            elapsed = min(time.time() - START, FINISH_AFTER)
            prog = 0.2 + 0.6 * elapsed / FINISH_AFTER
            st = {'state': 'complete' if done() else 'printing', 'filename': 'benchy.gcode',
                  'print_duration': DURATION * prog, 'filament_used': 1500.0 * prog}
            res = {'status': {'print_stats': st, 'virtual_sdcard': {'progress': 1.0 if done() else prog},
                              'extruder': {'temperature': 215, 'target': 215},
                              'heater_bed': {'temperature': 60, 'target': 60}}}
        elif self.path.startswith('/server/history/list'):
            jobs = []
            if done():
                jobs.append({'job_id': '000042', 'filename': 'benchy.gcode', 'status': 'completed',
                             'start_time': START - DURATION, 'end_time': START + FINISH_AFTER,
                             'print_duration': DURATION, 'filament_used': 1500.0,
                             'metadata': {'filament_weight_total': 4.6}})
            res = {'jobs': jobs, 'count': len(jobs)}
        else:
            res = {}
        body = json.dumps({'result': res}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(('0.0.0.0', 7125), H).serve_forever()
