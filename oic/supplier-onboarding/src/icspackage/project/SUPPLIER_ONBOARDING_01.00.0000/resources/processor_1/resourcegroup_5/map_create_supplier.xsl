<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="CheckExistingSupplier" select="()"/>
   <xsl:param name="CreateSupplier" select="()"/>
   <xsl:param name="DefaultProcurementBU" select="'US1 Business Unit'"/>
   <xsl:param name="FaultMessage" select="'Unexpected error while creating the supplier in Oracle ERP Cloud.'"/>
   <xsl:template match="/">
      <xsl:variable name="req" select="/src:SupplierOnboardingRequest"/>
      <erp:Supplier>
         <erp:Supplier><xsl:value-of select="normalize-space($req/src:supplierName)"/></erp:Supplier>
         <erp:TaxOrganizationType><xsl:value-of select="($req/src:taxOrganizationType[normalize-space()], 'Corporation')[1]"/></erp:TaxOrganizationType>
         <erp:SupplierType><xsl:value-of select="($req/src:supplierType[normalize-space()], 'Supplier')[1]"/></erp:SupplierType>
         <erp:TaxpayerId><xsl:value-of select="$req/src:taxRegistrationNumber"/></erp:TaxpayerId>
         <xsl:if test="$req/src:dunsNumber[normalize-space()]"><erp:DUNSNumber><xsl:value-of select="$req/src:dunsNumber"/></erp:DUNSNumber></xsl:if>
         <erp:BusinessRelationship>SPEND_AUTHORIZED</erp:BusinessRelationship>
      </erp:Supplier>
   </xsl:template>
</xsl:stylesheet>
