# -*- coding: utf-8 -*-
from django.conf.urls.defaults import *
from ragendja.urlsauto import urlpatterns
from ragendja.auth.urls import urlpatterns as auth_patterns
from django.contrib import admin

admin.autodiscover()

handler500 = 'ragendja.views.server_error'

urlpatterns = patterns(
    '',
    url(r'', include('goat.urls')),
    )

urlpatterns = auth_patterns + patterns('',
    ('^admin/(.*)', admin.site.root),
) + urlpatterns
