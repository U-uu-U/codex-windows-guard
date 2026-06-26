# Gitignore Snippet for Large Codex Workspaces

When a repository contains generated render output, browser profiles, cache folders, or large exported assets, add ignore rules before using Git-aware tools.

```gitignore
node_modules/
dist/
build/
.vite/
.cache/
render_tmp*/
template_tmp/
**/lo_profile/
**/*_temp/
**/*.tmp
**/qa/render_*/
**/qa/*_render_*/
**/qa/server_*.log
**/qa/server_*.err.log
**/qa/platform_server_*.log
**/qa/platform_server_*.err.log
qa/profile_*/
qa/profile_chrome_*/
qa/profile_msedge_*/
qa/*webshot_profile*/
webshot_temp/
**/Cache/
**/Code Cache/
**/GPUCache/
**/Session Storage/
**/Local Storage/
**/IndexedDB/
**/Service Worker/
**/PersistentOriginTrials/
**/LOCK
**/LOG
**/MANIFEST-*
```

This is not a universal ignore file. Review it before committing it to a project.
