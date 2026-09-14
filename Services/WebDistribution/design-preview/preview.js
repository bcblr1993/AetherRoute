(() => {
  const image = document.querySelector('#product');
  const labels = { overview: '概览', proxies: '节点管理', connections: '实时连接' };
  const buttons = [...document.querySelectorAll('[data-view]')];
  buttons.forEach((button, index) => button.addEventListener('click', () => {
    image.src = `../public/assets/aetherroute-${button.dataset.view}-zh.png`;
    image.alt = `AetherRoute 实际中文${labels[button.dataset.view]}界面`;
    buttons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    document.querySelector('.stage-number').textContent = `0${index + 1} / 03`;
  }));
})();
