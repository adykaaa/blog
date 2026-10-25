(() => {
  document.querySelectorAll('[data-quiz]').forEach((quiz) => {
    const form = quiz.querySelector('.quiz-form');
    const questions = [...form.querySelectorAll('.quiz-question')];
    const progress = form.querySelector('.quiz-progress');
    const message = form.querySelector('.quiz-message');
    const result = form.querySelector('.quiz-result');
    const submit = form.querySelector('[type="submit"]');
    const retryButtons = form.querySelectorAll('[data-quiz-retry]');

    const updateProgress = () => {
      const answered = questions.filter((question) => question.querySelector('input:checked')).length;
      progress.textContent = `${answered} of ${questions.length} questions answered.`;
    };

    form.addEventListener('change', (event) => {
      if (!event.target.matches('input')) return;
      const question = event.target.closest('.quiz-question');
      if (question.querySelector('input:checked')) {
        delete question.dataset.state;
        question.querySelectorAll('input').forEach((input) => input.removeAttribute('aria-invalid'));
      }
      message.hidden = true;
      updateProgress();
    });

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const unanswered = questions.filter((question) => !question.querySelector('input:checked'));

      if (unanswered.length) {
        message.textContent = `Answer every question before checking. ${unanswered.length} ${unanswered.length === 1 ? 'question still needs' : 'questions still need'} an answer.`;
        message.hidden = false;
        unanswered.forEach((question) => {
          question.dataset.state = 'unanswered';
          question.querySelectorAll('input').forEach((input) => input.setAttribute('aria-invalid', 'true'));
        });
        unanswered[0].querySelector('input').focus();
        return;
      }

      let score = 0;
      questions.forEach((question) => {
        const inputs = [...question.querySelectorAll('input')];
        const correct = inputs.every((input) => input.checked === input.hasAttribute('data-correct'));
        if (correct) score += 1;
        question.dataset.state = correct ? 'correct' : 'incorrect';
        question.querySelector('.quiz-outcome').textContent = correct ? 'Correct.' : 'Incorrect.';
        const feedback = question.querySelector('.quiz-feedback');
        feedback.hidden = false;
        question.setAttribute('aria-describedby', `${question.querySelector('.quiz-hint').id} ${feedback.id}`);

        inputs.forEach((input) => {
          const choice = input.closest('.quiz-choice');
          const note = choice.querySelector('.quiz-choice-note');
          if (input.hasAttribute('data-correct')) {
            choice.classList.add('is-correct');
            note.textContent = input.checked ? 'Your answer — correct' : 'Correct answer';
          } else if (input.checked) {
            choice.classList.add('is-incorrect');
            note.textContent = 'Your answer — incorrect';
          }
          input.disabled = true;
        });
      });

      message.hidden = true;
      form.querySelector('.quiz-score').textContent = `You scored ${score} / ${questions.length} (${Math.round(score / questions.length * 100)}%).`;
      result.hidden = false;
      submit.hidden = true;
      retryButtons.forEach((button) => { button.hidden = false; });
      result.focus();
    });

    form.addEventListener('reset', () => {
      questions.forEach((question) => {
        delete question.dataset.state;
        question.querySelector('.quiz-feedback').hidden = true;
        question.setAttribute('aria-describedby', question.querySelector('.quiz-hint').id);
        question.querySelector('.quiz-outcome').textContent = '';
        question.querySelectorAll('input').forEach((input) => {
          input.checked = false;
          input.disabled = false;
          input.removeAttribute('aria-invalid');
        });
        question.querySelectorAll('.quiz-choice').forEach((choice) => {
          choice.classList.remove('is-correct', 'is-incorrect');
          choice.querySelector('.quiz-choice-note').textContent = '';
        });
      });
      result.hidden = true;
      message.hidden = true;
      submit.hidden = false;
      retryButtons.forEach((button) => { button.hidden = true; });
      updateProgress();
      questions[0].querySelector('input').focus();
    });

    updateProgress();
    quiz.querySelector('.quiz-unavailable').hidden = true;
    form.hidden = false;
  });
})();
