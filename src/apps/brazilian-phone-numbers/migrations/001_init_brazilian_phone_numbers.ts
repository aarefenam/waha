import { migrations_001_init_cache } from '@waha/apps/phone-numbers/storage/migrations_001_init_cache';

const migration = migrations_001_init_cache({
  table: 'app_brazilian_phone_numbers_cache',
  index: 'brphone',
});

exports.up = migration.up;
exports.down = migration.down;
