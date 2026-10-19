(() => {
  const select=document.getElementById('scenario'), frame=document.getElementById('live-prototype');
  select.addEventListener('change',()=>{frame.src=`command-wheel.html?frame=${encodeURIComponent(select.value)}`;});
})();
