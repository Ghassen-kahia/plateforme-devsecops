# Image du frontend — VERSION INITIALE (Phase 1), durcie en Phase 2.
FROM nginx:1.30.5

COPY index.html style.css app.js /usr/share/nginx/html/
COPY default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 8080
