import 'package:meshtasks/model/quick_add.dart';
import 'package:meshtasks/model/voice.dart';
import 'package:test/test.dart';

final now = DateTime(2026, 10, 17, 10); // Saturday
const projects = ['Ventas', 'Website relaunch', 'Operaciones'];
const members = ['Ana Gómez', 'Luis Pérez'];

QuickAdd say(String spoken) => parseQuickAdd(
    spokenToQuickAdd(spoken, projects: projects, members: members),
    now: now, projects: projects, members: members);

void main() {
  test('spanish: time words, priority, project, assignee', () {
    final q = say('Llamar al cliente mañana a las tres de la tarde prioridad uno en el proyecto ventas asignar a Ana');
    expect(q.title, 'Llamar al cliente');
    expect(q.due.toString(), '2026-10-18T15:00');
    expect(q.priority, 1);
    expect(q.project, 'Ventas');
    expect(q.assignee, 'Ana Gómez');
  });

  test('spanish recognizer output with p. m. and commas', () {
    final q = say('Revisar inventario, el lunes, 4:30 p. m., prioridad alta.');
    expect(q.title, 'Revisar inventario');
    expect(q.due.toString(), '2026-10-19T16:30');
    expect(q.priority, 1);
  });

  test('spanish half past, repeats, label, private', () {
    final q = say('Pagar nómina todos los viernes a las 9 y media etiqueta finanzas tarea privada');
    expect(q.title, 'Pagar nómina');
    expect(q.recur.toString(), 'every fri');
    expect(q.due.toString(), '2026-10-23T09:30');
    expect(q.labels, ['finanzas']);
    expect(q.private, isTrue);
  });

  test('spanish relative dates', () {
    expect(say('Enviar propuesta dentro de dos días').due.toString(), '2026-10-19');
    expect(say('Enviar propuesta la próxima semana').due.toString(), '2026-10-19');
    expect(say('Renovar dominio el 20 de noviembre').due.toString(), '2026-11-20');
    expect(say('Renovar dominio el 20 de noviembre').title, 'Renovar dominio');
    expect(say('Standup de lunes a viernes a las 9 de la mañana').recur.toString(), 'every weekday');
    expect(say('Reunión al mediodía').due.toString(), '2026-10-17T12:00'); // still ahead at 10:00
  });

  test('english', () {
    final q = say('Send the report next friday at 5 p.m. priority two project website relaunch assign to luis');
    expect(q.title, 'Send the report');
    expect(q.due.toString(), '2026-10-23T17:00');
    expect(q.priority, 2);
    expect(q.project, 'Website relaunch');
    expect(q.assignee, 'Luis Pérez');
  });

  test('english dates, repeats, private', () {
    expect(say('Water the plants every day at seven am').due.toString(), '2026-10-17T07:00');
    expect(say('Renew the domain on October 20th').due.toString(), '2026-10-20');
    expect(say('Renew the domain on October 20th').title, 'Renew the domain');
    expect(say('Call the dentist in three days').due.toString(), '2026-10-20');
    final q = say('Buy a birthday gift for Ana just for me');
    expect(q.private, isTrue);
    expect(q.title, 'Buy a birthday gift for Ana');
  });

  test('plain sentences stay intact', () {
    expect(say('Una reunión con dos clientes').title, 'Una reunión con dos clientes');
    expect(say('Book a private room for the offsite').private, isFalse);
    expect(say('Book a private room for the offsite').title, 'Book a private room for the offsite');
  });

  test('alarms and reminders by voice', () {
    final q = say('Tomar la medicina a las 8 de la noche con alarma y recuérdame 15 minutos antes');
    expect(q.title, 'Tomar la medicina');
    expect(q.due.toString(), '2026-10-17T20:00');
    expect(q.alarm, isTrue);
    expect(q.reminders, [15]);
    final e = say('Submit the report tomorrow at 9 am with an alarm remind me an hour before');
    expect(e.title, 'Submit the report');
    expect(e.alarm, isTrue);
    expect(e.reminders, [60]);
  });
}
