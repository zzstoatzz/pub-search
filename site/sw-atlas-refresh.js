self.addEventListener('activate', function(event) {
  event.waitUntil(self.clients.matchAll({type: 'window', includeUncontrolled: true}).then(function(clients) {
    clients.filter(function(client) {
      return /^\/atlas(?:\.html)?\/?$/.test(new URL(client.url).pathname);
    }).forEach(function(client) {
      void client.navigate(client.url).catch(function() {});
    });
  }));
});
