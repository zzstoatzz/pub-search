// shared: bluesky-compatible client registry + preferred-client preference.
// mirrors the shape used in ../@zzstoatzz.io/status and ../@chicago.at so
// users get consistent behavior across these atproto experiments.
//
// stored in localStorage under `leaflet.preferredClient`. default = bsky.
// `profileUrlFor(handle)` returns the resolved profile URL for the current
// preference; unknown values fall back to the first registered client.

(function() {
  'use strict';

  var STORAGE_KEY = 'leaflet.preferredClient';

  var CLIENTS = [
    { value: 'bsky',     label: 'Bluesky',   profileUrl: function(h) { return 'https://bsky.app/profile/' + h; },          iconUrl: 'https://web-cdn.bsky.app/static/apple-touch-icon.png' },
    { value: 'blacksky', label: 'Blacksky',  profileUrl: function(h) { return 'https://blacksky.community/profile/' + h; }, iconUrl: 'https://blacksky.community/static/apple-touch-icon.png' },
    { value: 'witchsky', label: 'Witchsky',  profileUrl: function(h) { return 'https://witchsky.app/profile/' + h; },       iconUrl: 'https://witchsky.app/favicon.ico' },
    { value: 'reddwarf', label: 'Red Dwarf', profileUrl: function(h) { return 'https://reddwarf.app/profile/' + h; },       iconUrl: 'https://reddwarf.app/redstar.png' },
    { value: 'pdsls',    label: 'PDSls',     profileUrl: function(h) { return 'https://pdsls.dev/at/' + h; },               iconUrl: 'https://pdsls.dev/favicon.ico' },
  ];

  function readPreferred() {
    try { return localStorage.getItem(STORAGE_KEY); } catch (e) { return null; }
  }

  function writePreferred(value) {
    try { localStorage.setItem(STORAGE_KEY, value); } catch (e) {}
  }

  function getPreferredClient() {
    var v = readPreferred();
    return CLIENTS.find(function(c) { return c.value === v; }) || CLIENTS[0];
  }

  function setPreferredClient(value) {
    if (CLIENTS.some(function(c) { return c.value === value; })) {
      writePreferred(value);
      window.dispatchEvent(new CustomEvent('leaflet:preferred-client-changed', { detail: value }));
    }
  }

  function profileUrlFor(handleOrDid) {
    return getPreferredClient().profileUrl(handleOrDid);
  }

  window.LeafletClients = {
    CLIENTS: CLIENTS,
    getPreferredClient: getPreferredClient,
    setPreferredClient: setPreferredClient,
    profileUrlFor: profileUrlFor,
  };
})();
