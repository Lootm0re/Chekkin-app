// Alerts raised by the checkInSpikes function: places with an unusual number
// of check-ins in an hour. Uses the firebase CLI's login, so run
// `firebase login` first.
//
//   node scripts/alerts.js list [count]   (newest first, default 20)

const { cliFirestore } = require('./cli-firestore');

async function list(db, count) {
  const alerts = await db.collection('alerts').orderBy('createdAt', 'desc').limit(count).get();
  if (alerts.empty) {
    console.log('No alerts.');
    return;
  }
  for (const alert of alerts.docs) {
    console.log([
      alert.get('createdAt')?.toDate().toISOString() ?? '?',
      alert.get('type'),
      alert.get('placeId'),
      alert.get('placeName'),
      `${alert.get('lastHour')} check-ins in an hour (usually ${alert.get('hourlyAverage')})`,
    ].join('  '));
  }
}

async function main() {
  const [command, count] = process.argv.slice(2);
  const db = cliFirestore();
  if (command === 'list') return list(db, Number(count) || 20);
  console.log('Usage: node scripts/alerts.js list [count]');
  process.exitCode = 1;
}

main().catch((err) => { console.error(err.message); process.exit(1); });
