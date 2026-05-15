// HASH256 GPU Miner — PM2 ecosystem file.
//
// Usage:
//   pm2 start ecosystem.config.js
//   pm2 logs hash256-miner
//   pm2 save                 # remember running processes
//
// Persistence on reboot WITHOUT systemd:
//   pm2 save
//   crontab -l 2>/dev/null | grep -v 'pm2 resurrect' > /tmp/cron.tmp
//   echo "@reboot $(which pm2) resurrect >/dev/null 2>&1" >> /tmp/cron.tmp
//   crontab /tmp/cron.tmp
//
// (`pm2 startup` itself writes a systemd unit. The cron line above
//  achieves the same restart-on-boot behavior using only your user's
//  crontab — no root systemd edits needed.)

const path = require('path');

module.exports = {
  apps: [
    {
      name: 'hash256-miner',
      cwd: __dirname,
      // Use the project venv's python so dependencies are isolated.
      script: path.join(__dirname, '.venv', 'bin', 'python'),
      args: ['-u', 'miner.py'],
      interpreter: 'none',  // tell PM2 not to wrap with node

      // Restart policy
      autorestart: true,
      max_restarts: 50,
      restart_delay: 30_000,           // 30s between crashes
      exp_backoff_restart_delay: 1_000, // gentle backoff on rapid failures
      max_memory_restart: '1G',

      // Logging
      out_file:  path.join(__dirname, 'miner.out.log'),
      error_file: path.join(__dirname, 'miner.err.log'),
      merge_logs: true,
      log_date_format: 'YYYY-MM-DD HH:mm:ss Z',

      // Environment is loaded by miner.py from .env, so PM2 doesn't need
      // to re-export anything. We just keep PATH so nvcc/cuda libs resolve.
      env: {
        PYTHONUNBUFFERED: '1',
      },
    },
  ],
};
