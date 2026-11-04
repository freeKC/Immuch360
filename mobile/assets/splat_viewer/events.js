// What the page tells the app: small JSON posts to the session's events, on the app's own origin (the media bridge
// takes 16 KiB at most). The app logs ready and stats under SplatViewer, keeps the orientation chosen with Turn
// upright, and closes the viewer on close. A post that fails is dropped: the page goes on.

export function createEvents(url) {
  return {
    post(type, fields = {}) {
      const body = JSON.stringify({ type, ...fields });
      try {
        return fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body,
          keepalive: body.length < 60000,
        }).then(() => true, () => false);
      } catch (error) {
        return Promise.resolve(false);
      }
    },
  };
}
