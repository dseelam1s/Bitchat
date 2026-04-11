from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path
from rest_framework_simplejwt.views import TokenRefreshView

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/v1/bitchat/', include('bitchat.urls')),
    path('api/v1/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),
]

# Serve uploaded media files in all environments.
# On Render the filesystem is ephemeral — files survive between requests
# within the same deployment but are lost on redeploy. Acceptable for
# profile pictures and message attachments (clients cache locally).
urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
