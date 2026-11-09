'use strict';

const els = {
  form: document.getElementById('new-task'),
  input: document.getElementById('title'),
  list: document.getElementById('tasks'),
  empty: document.getElementById('empty'),
  status: document.getElementById('status'),
  clearDone: document.getElementById('clear-done'),
  statTotal: document.getElementById('stat-total'),
  statOpen: document.getElementById('stat-open'),
  statDone: document.getElementById('stat-done'),
  filters: Array.from(document.querySelectorAll('[data-filter]'))
};

let tasks = [];
let stats = { total: 0, open: 0, done: 0 };
let filter = 'all';

function setStatus(message, isError = false) {
  els.status.textContent = message;
  els.status.classList.toggle('error', Boolean(isError));
}

function apply(snapshot) {
  tasks = Array.isArray(snapshot.tasks) ? snapshot.tasks : [];
  stats = snapshot.stats || { total: tasks.length, open: 0, done: 0 };
  render();
}

function visibleTasks() {
  if (filter === 'open') return tasks.filter(task => !task.done);
  if (filter === 'done') return tasks.filter(task => task.done);
  return tasks;
}

function render() {
  els.statTotal.textContent = stats.total;
  els.statOpen.textContent = stats.open;
  els.statDone.textContent = stats.done;
  els.filters.forEach(button =>
    button.setAttribute('aria-pressed', String(button.dataset.filter === filter)));

  els.list.replaceChildren();
  const visible = visibleTasks();
  for (const task of visible) els.list.append(taskRow(task));

  els.empty.hidden = visible.length !== 0;
  els.empty.textContent = tasks.length === 0
    ? 'Nothing here yet. Add the first task above.'
    : `No ${filter} tasks.`;
}

function taskRow(task) {
  const item = document.createElement('li');
  item.className = task.done ? 'task done' : 'task';

  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.checked = Boolean(task.done);
  checkbox.setAttribute('aria-label',
    `Mark "${task.title}" as ${task.done ? 'open' : 'done'}`);
  checkbox.addEventListener('change', () =>
    run(() => glaze.api.tasksToggle({ id: task.id }), 'Could not update the task'));

  const title = document.createElement('span');
  title.className = 'title';
  title.textContent = task.title;

  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'delete';
  remove.textContent = 'Delete';
  remove.setAttribute('aria-label', `Delete "${task.title}"`);
  remove.addEventListener('click', () =>
    run(() => glaze.api.tasksDelete({ id: task.id }), 'Could not delete the task'));

  item.append(checkbox, title, remove);
  return item;
}

async function run(action, failureMessage) {
  try {
    const snapshot = await action();
    if (snapshot) apply(snapshot);
    setStatus('');
  } catch (error) {
    setStatus(`${failureMessage}: ${error.message || error}`, true);
  }
}

els.form.addEventListener('submit', async event => {
  event.preventDefault();
  const title = els.input.value.trim();
  if (!title) {
    setStatus('Enter a task first.', true);
    els.input.focus();
    return;
  }
  try {
    const snapshot = await glaze.api.tasksCreate({ title });
    apply(snapshot);
    els.input.value = '';
    setStatus(`Added "${title}".`);
    els.input.focus();
  } catch (error) {
    setStatus(`Could not add the task: ${error.message || error}`, true);
  }
});

els.input.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    els.input.value = '';
    setStatus('');
  }
});

els.clearDone.addEventListener('click', () => {
  if (!stats.done) {
    setStatus('No done tasks to clear.');
    return;
  }
  run(() => glaze.api.tasksClearDone(), 'Could not clear done tasks');
});

els.filters.forEach(button => {
  button.addEventListener('click', () => {
    filter = button.dataset.filter;
    render();
  });
});

// The bus carries a fresh snapshot after every mutation, so a second window
// and this one converge without polling.
glaze.on('tasks-changed', apply);

glaze.api.tasks()
  .then(snapshot => {
    apply(snapshot);
    setStatus('Loaded from the Racket store.');
  })
  .catch(error => setStatus(`Could not load tasks: ${error.message || error}`, true));
