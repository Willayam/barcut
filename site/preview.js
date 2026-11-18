const controls = document.querySelector('.preview-controls');
const demo = document.querySelector('.demo');
const caption = document.querySelector('.preview figcaption');

const modes = {
  history: {
    description: 'A sample screenshot selected in BarCut history.',
    caption: 'The menu keeps your latest screenshots and copied images.',
  },
  annotate: {
    description: 'An arrow and the label “Check this spike” point to the tallest bar in a sample screenshot.',
    caption: 'Draw an arrow and start typing to label it.',
  },
  crop: {
    description: 'A crop frame isolates the activity chart in a sample screenshot.',
    caption: 'Drag the crop frame around the part you want to keep.',
  },
};

controls.hidden = false;
controls.addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button) return;

  const mode = button.dataset.mode;
  demo.dataset.mode = mode;
  demo.setAttribute('aria-label', modes[mode].description);
  caption.textContent = modes[mode].caption;

  for (const option of controls.querySelectorAll('button')) {
    option.setAttribute('aria-pressed', String(option === button));
  }
});
