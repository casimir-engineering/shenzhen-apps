(() => {
  const frame=document.getElementById('prototype');
  const buttons=[...document.querySelectorAll('[data-scene]')];
  const large=document.getElementById('large-text');
  function choose(button){
    buttons.forEach(b=>b.setAttribute('aria-pressed',String(b===button)));
    frame.src=`prototype.html?scene=${button.dataset.scene}${large.checked?'&large=1':''}`;
    document.getElementById('scene-caption').textContent=`${button.children[0].textContent} / ${button.querySelector('strong').textContent} · Interactive design prototype`;
  }
  buttons.forEach(button=>button.addEventListener('click',()=>choose(button)));
  large.addEventListener('change',()=>choose(buttons.find(b=>b.getAttribute('aria-pressed')==='true')));
})();
